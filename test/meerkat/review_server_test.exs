defmodule Meerkat.ReviewServerTest do
  # async: false — uses a global Registry / DynamicSupervisor shared
  # across tests; each test allocates a fresh review_id so they
  # don't collide, but DynamicSupervisor.children/1 walks the full
  # list.
  use Meerkat.Case, async: false

  alias Meerkat.{Comment, Persistence, ReviewServer, ReviewState}

  setup do
    repo = make_tmp_repo()
    id = "rs_#{System.unique_integer([:positive])}"

    # Defensive: terminate any leftover GenServer registered under
    # this id. `System.unique_integer/1` is unique within a BEAM, but
    # if a prior test in another file left a `ReviewServer` running
    # under the SAME id, `ensure_started` would return that stale pid
    # with its leaked state.
    case Registry.lookup(Meerkat.ReviewRegistry, id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Meerkat.ReviewServerSup, pid)
      _ -> :ok
    end

    on_exit(fn ->
      case Registry.lookup(Meerkat.ReviewRegistry, id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Meerkat.ReviewServerSup, pid)
        _ -> :ok
      end

      File.rm_rf!(repo)
    end)

    {:ok, repo: repo, review_id: id}
  end

  describe "ensure_started/2" do
    test "idempotent — same review_id returns the same pid", %{repo: repo, review_id: id} do
      {:ok, pid1} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      {:ok, pid2} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      assert pid1 == pid2
    end

    test "different review_ids → different pids", %{repo: repo} do
      {:ok, pid_a} =
        ReviewServer.ensure_started("rs_a_#{System.unique_integer([:positive])}", %{
          repo_path: repo,
          initial_state: %ReviewState{}
        })

      {:ok, pid_b} =
        ReviewServer.ensure_started("rs_b_#{System.unique_integer([:positive])}", %{
          repo_path: repo,
          initial_state: %ReviewState{}
        })

      refute pid_a == pid_b
    end

    test "registers the server under the given id, whatever review_id the args hold",
         %{repo: repo, review_id: id} do
      {:ok, pid} =
        ReviewServer.ensure_started(id, %{
          repo_path: repo,
          initial_state: %ReviewState{},
          review_id: "#{id}_stale"
        })

      assert [{^pid, _}] = Registry.lookup(Meerkat.ReviewRegistry, id)
      assert %ReviewState{} = ReviewServer.get_state(id)
    end

    test "starts from the snapshot an earlier server saved", %{repo: repo, review_id: id} do
      saved = %ReviewState{approved_file_names: MapSet.new(["a.ex"])}
      :ok = Persistence.save(repo, id, saved)

      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      assert MapSet.equal?(ReviewServer.get_state(id).approved_file_names, MapSet.new(["a.ex"]))
    end
  end

  test "topic/1 is the review id prefixed with review:" do
    assert ReviewServer.topic("abc") == "review:abc"
  end

  describe "single-writer + broadcast" do
    test "add_global_comment broadcasts {:state_changed, state}", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      Phoenix.PubSub.subscribe(Meerkat.PubSub, ReviewServer.topic(id))

      comment = %{
        id: Comment.new_id(),
        body: "global!",
        finding_type: :issue,
        correct_instructions: true,
        lint_rule: false,
        created_at: Comment.now()
      }

      new_state = ReviewServer.add_comment(id, :global, comment)
      assert [^comment] = new_state.global_comments

      assert_receive {:state_changed, %ReviewState{global_comments: [^comment]}}
    end

    test "remove_comment/3 takes effect for matching surface + id",
         %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      cid = Comment.new_id()

      _ =
        ReviewServer.add_comment(id, :global, %{
          id: cid,
          body: "x",
          finding_type: :issue,
          correct_instructions: false,
          lint_rule: false,
          created_at: Comment.now()
        })

      after_remove = ReviewServer.remove_comment(id, :global, cid)
      assert after_remove.global_comments == []
    end

    test "set_approved toggles MapSet membership", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      _ = ReviewServer.set_approved(id, "src/main.rs", true)
      _ = ReviewServer.set_approved(id, "NOTES.md", true)
      _ = ReviewServer.set_approved(id, "src/main.rs", false)
      state = ReviewServer.get_state(id)

      assert MapSet.equal?(state.approved_file_names, MapSet.new(["NOTES.md"]))
    end

    test "set_extension_hidden toggles MapSet membership", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      _ = ReviewServer.set_extension_hidden(id, "lock", true)
      _ = ReviewServer.set_extension_hidden(id, "snap", true)
      _ = ReviewServer.set_extension_hidden(id, "lock", false)
      state = ReviewServer.get_state(id)

      assert MapSet.equal?(state.hidden_extensions, MapSet.new(["snap"]))
    end

    test "mutation persists to disk after every change", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      _ = ReviewServer.set_approved(id, "src/main.rs", true)
      loaded = Persistence.load(repo, id, %ReviewState{})

      assert MapSet.equal?(loaded.approved_file_names, MapSet.new(["src/main.rs"]))
    end
  end

  describe "the reply wait" do
    setup do
      previous = Application.fetch_env(:meerkat, :review_server_call_timeout_ms)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:meerkat, :review_server_call_timeout_ms, value)
          :error -> Application.delete_env(:meerkat, :review_server_call_timeout_ms)
        end
      end)
    end

    test "is 5 s unless the app env sets it" do
      Application.delete_env(:meerkat, :review_server_call_timeout_ms)
      assert ReviewServer.call_timeout_ms() == 5_000

      Application.put_env(:meerkat, :review_server_call_timeout_ms, 7)
      assert ReviewServer.call_timeout_ms() == 7
    end

    test "bounds every call to a server that does not answer", %{repo: repo, review_id: id} do
      {:ok, pid} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      Application.put_env(:meerkat, :review_server_call_timeout_ms, 50)
      :sys.suspend(pid)

      try do
        assert {:timeout, {GenServer, :call, [_, :get_state, 50]}} =
                 catch_exit(ReviewServer.get_state(id))

        assert {:timeout, {GenServer, :call, [^pid, :delete_snapshot, 50]}} =
                 catch_exit(ReviewServer.delete_snapshot(repo, id))
      after
        :sys.resume(pid)
      end
    end
  end

  describe "argument guards" do
    test "reject a negative file index, a non-binary comment id and an unknown or non-boolean flag",
         %{review_id: id} do
      assert_raise FunctionClauseError, fn -> ReviewServer.get_file_at(id, -1) end
      # Read back at runtime so the compiler's type check doesn't flag them.
      non_binary_id = Process.get(:non_binary_id, 1)
      non_boolean = Process.get(:non_boolean, "yes")

      assert_raise FunctionClauseError, fn ->
        ReviewServer.remove_comment(id, :global, non_binary_id)
      end

      assert_raise FunctionClauseError, fn ->
        ReviewServer.set_flag(id, :global, "c1", :lint_rule, non_boolean)
      end

      unknown_flag = Process.get(:unknown_flag, :finding_type)

      assert_raise FunctionClauseError, fn ->
        ReviewServer.set_flag(id, :global, "c1", unknown_flag, true)
      end
    end

    # No server runs for `id`, so a call that got past its guard would
    # exit rather than raise.
    test "reject every other ill-typed or unknown argument", %{review_id: id} do
      # Read back at runtime so the compiler's type check doesn't flag them.
      bogus = Process.get(:bogus, :bogus)
      not_binary = Process.get(:not_binary, 1)
      not_boolean = Process.get(:not_boolean, "yes")
      not_map = Process.get(:not_map, [])

      calls = [
        fn -> ReviewServer.ensure_started(not_binary, %{repo_path: "", initial_state: nil}) end,
        fn -> ReviewServer.add_comment(id, bogus, %{}) end,
        fn -> ReviewServer.remove_comment(id, bogus, "c1") end,
        fn -> ReviewServer.set_flag(id, bogus, "c1", :lint_rule, true) end,
        fn -> ReviewServer.set_flag(id, :global, not_binary, :lint_rule, true) end,
        fn -> ReviewServer.set_approved(id, "a.ex", not_boolean) end,
        fn -> ReviewServer.set_extension_hidden(id, "ex", not_boolean) end,
        fn -> ReviewServer.set_file_override(id, not_binary, :show) end,
        fn -> ReviewServer.set_file_override(id, "a.ex", bogus) end,
        fn -> ReviewServer.set_file_overrides(id, not_map) end,
        fn -> ReviewServer.set_show_generated(id, not_boolean) end,
        fn -> ReviewServer.open_form(id, not_map) end,
        fn -> ReviewServer.close_form(id, not_binary) end
      ]

      for call <- calls, do: assert_raise(FunctionClauseError, call)
    end
  end

  describe "set_file_override/3" do
    test "shows or hides a file, and :default drops its override",
         %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      _ = ReviewServer.set_file_override(id, "a.ex", :show)
      _ = ReviewServer.set_file_override(id, "b.ex", :hide)
      assert ReviewServer.get_state(id).file_overrides == %{"a.ex" => :show, "b.ex" => :hide}

      assert ReviewServer.set_file_override(id, "a.ex", :default).file_overrides ==
               %{"b.ex" => :hide}
    end

    test "the server refuses an unknown decision that skips the client's guard",
         %{repo: repo, review_id: id} do
      {:ok, pid} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      ExUnit.CaptureLog.capture_log(fn ->
        assert {{:function_clause, _}, _} =
                 catch_exit(GenServer.call(pid, {:set_file_override, "a.ex", :bogus}))
      end)
    end
  end

  describe "a failed save" do
    test "keeps the mutation in memory and broadcasts :persistence_failed",
         %{repo: repo, review_id: id} do
      # A directory where the snapshot file belongs makes every save fail.
      File.mkdir_p!(Persistence.path_for(repo, id))

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {:ok, _} =
            ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

          Phoenix.PubSub.subscribe(Meerkat.PubSub, ReviewServer.topic(id))
          state = ReviewServer.set_approved(id, "a.ex", true)
          assert MapSet.member?(state.approved_file_names, "a.ex")
        end)

      assert_receive {:persistence_failed, reason}

      warning =
        "meerkat: warning — couldn't persist review #{id} state: #{inspect(reason)}. " <>
          "In-memory state preserved; comments may be lost if the BEAM dies before next save."

      assert warning in String.split(stderr, "\n")
    end
  end

  describe "delete_snapshot/2" do
    test "deletes the running server's snapshot, which no later mutation recreates",
         %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      _ = ReviewServer.set_approved(id, "a.ex", true)
      assert File.exists?(Persistence.path_for(repo, id))

      {:ok, _} = Meerkat.Decision.submit({:approve, ""})
      assert :ok = ReviewServer.delete_snapshot(repo, id)
      refute File.exists?(Persistence.path_for(repo, id))

      state = ReviewServer.set_approved(id, "b.ex", true)
      assert MapSet.member?(state.approved_file_names, "b.ex")
      refute File.exists?(Persistence.path_for(repo, id))
    end

    test "deletes the snapshot when no server is running", %{repo: repo, review_id: id} do
      :ok = Persistence.save(repo, id, %ReviewState{})
      assert File.exists?(Persistence.path_for(repo, id))

      assert :ok = ReviewServer.delete_snapshot(repo, id)
      refute File.exists?(Persistence.path_for(repo, id))
    end
  end

  describe "clear_all_comments/1" do
    test "wipes all four surfaces in a single broadcast", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      _ =
        ReviewServer.add_comment(id, :inline, %{
          id: Comment.new_id(),
          file_index: 0,
          start_line: 1,
          end_line: 1,
          side: :new,
          body: "x",
          finding_type: :issue,
          correct_instructions: false,
          lint_rule: false,
          created_at: Comment.now()
        })

      _ =
        ReviewServer.add_comment(id, :file, %{
          id: Comment.new_id(),
          file_index: 0,
          body: "x",
          finding_type: :issue,
          correct_instructions: false,
          lint_rule: false,
          created_at: Comment.now()
        })

      _ =
        ReviewServer.add_comment(id, :global, %{
          id: Comment.new_id(),
          body: "x",
          finding_type: :issue,
          correct_instructions: false,
          lint_rule: false,
          created_at: Comment.now()
        })

      _ =
        ReviewServer.add_comment(id, :commit_msg, %{
          id: Comment.new_id(),
          start_line: 1,
          end_line: 1,
          body: "x",
          finding_type: :issue,
          correct_instructions: false,
          lint_rule: false,
          created_at: Comment.now()
        })

      # Subscribe AFTER seeding so the test only receives the wipe
      # broadcast — N seed adds produce N broadcasts otherwise.
      Phoenix.PubSub.subscribe(Meerkat.PubSub, ReviewServer.topic(id))

      after_wipe = ReviewServer.clear_all_comments(id)

      assert after_wipe.comments == []
      assert after_wipe.file_comments == []
      assert after_wipe.global_comments == []
      assert after_wipe.commit_message_comments == []

      # Exactly one broadcast for the whole wipe — that's the entire
      # point of consolidating vs N remove_comment calls.
      assert_receive {:state_changed, %ReviewState{}}
      refute_receive {:state_changed, _}, 100
    end
  end

  describe "get_file_at/2" do
    test "returns {:ok, file} for an in-range index", %{repo: repo, review_id: id} do
      files = [
        %{file_name: "a.rs", old_content: "old-a", new_content: "new-a"},
        %{file_name: "b.rs", old_content: "old-b", new_content: "new-b"}
      ]

      {:ok, _} =
        ReviewServer.ensure_started(id, %{
          repo_path: repo,
          initial_state: %ReviewState{files: files}
        })

      assert {:ok, %{file_name: "a.rs"}} = ReviewServer.get_file_at(id, 0)
      assert {:ok, %{file_name: "b.rs"}} = ReviewServer.get_file_at(id, 1)
    end

    test "returns :not_found for out-of-range index", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{
          repo_path: repo,
          initial_state: %ReviewState{files: [%{file_name: "only.rs"}]}
        })

      assert ReviewServer.get_file_at(id, 1) == :not_found
      assert ReviewServer.get_file_at(id, 99) == :not_found
    end
  end

  describe "set_flag/5" do
    test "sets each flag on the matching comment only, leaving the other flag alone", %{
      repo: repo,
      review_id: id
    } do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      [cid, other] =
        for body <- ["needs work", "other"] do
          comment = %{
            id: Comment.new_id(),
            body: body,
            finding_type: :issue,
            correct_instructions: false,
            lint_rule: false,
            created_at: Comment.now()
          }

          _ = ReviewServer.add_comment(id, :global, comment)
          comment.id
        end

      _ = ReviewServer.set_flag(id, :global, cid, :correct_instructions, true)

      assert [
               %{id: ^cid, correct_instructions: true, lint_rule: false},
               %{id: ^other, correct_instructions: false, lint_rule: false}
             ] = ReviewServer.get_state(id).global_comments

      _ = ReviewServer.set_flag(id, :global, cid, :lint_rule, true)
      _ = ReviewServer.set_flag(id, :global, cid, :correct_instructions, false)

      assert [
               %{id: ^cid, correct_instructions: false, lint_rule: true},
               %{id: ^other, correct_instructions: false, lint_rule: false}
             ] = ReviewServer.get_state(id).global_comments
    end

    test "is a no-op for an unknown id", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      _ = ReviewServer.set_flag(id, :global, "nonexistent-id", :lint_rule, true)
      assert ReviewServer.get_state(id).global_comments == []
    end

    test "works across all four surfaces", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      inline_id = Comment.new_id()

      _ =
        ReviewServer.add_comment(id, :inline, %{
          id: inline_id,
          file_index: 0,
          start_line: 1,
          end_line: 1,
          side: :new,
          body: "x",
          finding_type: :issue,
          correct_instructions: false,
          lint_rule: false,
          created_at: Comment.now()
        })

      _ = ReviewServer.set_flag(id, :inline, inline_id, :lint_rule, true)
      assert [%{lint_rule: true}] = ReviewServer.get_state(id).comments
    end
  end

  describe "each comment surface" do
    @surfaces [
      inline: :comments,
      file: :file_comments,
      global: :global_comments,
      commit_msg: :commit_message_comments
    ]

    setup %{repo: repo, review_id: id} do
      initial =
        Enum.reduce(@surfaces, %ReviewState{}, fn {surface, key}, state ->
          Map.put(state, key, [%{id: "#{surface}", lint_rule: false}])
        end)

      {:ok, _} = ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: initial})
      :ok
    end

    test "takes set_flag/5 on its own list", %{review_id: id} do
      for {surface, key} <- @surfaces do
        state = ReviewServer.set_flag(id, surface, "#{surface}", :lint_rule, true)
        assert [%{lint_rule: true}] = Map.fetch!(state, key)
      end
    end

    test "takes remove_comment/3 on its own list", %{review_id: id} do
      for {surface, key} <- @surfaces do
        assert ReviewServer.remove_comment(id, surface, "#{surface}") |> Map.fetch!(key) == []
      end
    end
  end

  describe "open_form/2 + close_form/2" do
    test "opens forms alongside each other, in order", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      first = %{
        surface: :inline,
        anchor: %{file_index: 0, start_line: 4, end_line: 6, side: "new"}
      }

      second = %{surface: :global, anchor: %{}}

      _ = ReviewServer.open_form(id, first)
      _ = ReviewServer.open_form(id, second)
      assert ReviewServer.get_state(id).open_forms == [first, second]
    end

    test "close_form/2 closes only the form with that key", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      inline = %{
        surface: :inline,
        anchor: %{file_index: 0, start_line: 1, end_line: 1, side: "new"}
      }

      _ = ReviewServer.open_form(id, %{surface: :global, anchor: %{}})
      _ = ReviewServer.open_form(id, inline)
      _ = ReviewServer.close_form(id, "global")
      assert ReviewServer.get_state(id).open_forms == [inline]
    end

    test "remove_comment/3 closes the forms editing that comment, and only those",
         %{repo: repo, review_id: id} do
      comment = fn cid ->
        %{id: cid, body: cid, finding_type: :issue, correct_instructions: false, lint_rule: false}
      end

      {:ok, _} =
        ReviewServer.ensure_started(id, %{
          repo_path: repo,
          initial_state: %ReviewState{global_comments: [comment.("g1"), comment.("g2")]}
        })

      add = %{surface: :global, anchor: %{}}
      edit_g1 = %{surface: :global, anchor: %{}, edit_id: "g1"}
      edit_g2 = %{surface: :global, anchor: %{}, edit_id: "g2"}
      for form <- [add, edit_g1, edit_g2], do: ReviewServer.open_form(id, form)

      state = ReviewServer.remove_comment(id, :global, "g1")
      assert [%{id: "g2"}] = state.global_comments
      assert state.open_forms == [add, edit_g2]
    end

    test "broadcasts {:state_changed, state}", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      Phoenix.PubSub.subscribe(Meerkat.PubSub, ReviewServer.topic(id))

      form = %{surface: :global, anchor: %{}}
      _ = ReviewServer.open_form(id, form)

      assert_receive {:state_changed, %ReviewState{open_forms: [^form]}}
    end

    test "persists across a process restart via Persistence", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      form = %{
        surface: :inline,
        anchor: %{file_index: 1, start_line: 10, end_line: 12, side: "old"}
      }

      _ = ReviewServer.open_form(id, form)

      loaded = Persistence.load(repo, id, %ReviewState{})
      assert [loaded_form] = loaded.open_forms
      assert loaded_form.surface == :inline
      assert loaded_form.anchor.file_index == 1
      assert loaded_form.anchor.start_line == 10
      assert loaded_form.anchor.end_line == 12
      assert loaded_form.anchor.side == "old"
    end
  end

  defp make_tmp_repo, do: Meerkat.TestHelpers.make_tmp_repo("meerkat-review-server")
end
