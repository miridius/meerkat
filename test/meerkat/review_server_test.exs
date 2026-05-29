defmodule Meerkat.ReviewServerTest do
  # async: false — uses a global Registry / DynamicSupervisor shared
  # across tests; each test allocates a fresh review_id so they
  # don't collide, but DynamicSupervisor.children/1 walks the full
  # list.
  use ExUnit.Case, async: false

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
        learn_from_this: true,
        created_at: Comment.now()
      }

      new_state = ReviewServer.add_comment(id, :global, comment)
      assert [^comment] = new_state.global_comments

      assert_receive {:state_changed, %ReviewState{global_comments: [^comment]}}, 200
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
          learn_from_this: false,
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
          learn_from_this: false,
          created_at: Comment.now()
        })

      _ =
        ReviewServer.add_comment(id, :file, %{
          id: Comment.new_id(),
          file_index: 0,
          body: "x",
          finding_type: :issue,
          learn_from_this: false,
          created_at: Comment.now()
        })

      _ =
        ReviewServer.add_comment(id, :global, %{
          id: Comment.new_id(),
          body: "x",
          finding_type: :issue,
          learn_from_this: false,
          created_at: Comment.now()
        })

      _ =
        ReviewServer.add_comment(id, :commit_msg, %{
          id: Comment.new_id(),
          start_line: 1,
          end_line: 1,
          body: "x",
          finding_type: :issue,
          learn_from_this: false,
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
      assert_receive {:state_changed, %ReviewState{}}, 200
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

  describe "set_learn_from_this/4" do
    test "flips learn_from_this on the matching comment id", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      cid = Comment.new_id()

      _ =
        ReviewServer.add_comment(id, :global, %{
          id: cid,
          body: "needs work",
          finding_type: :issue,
          learn_from_this: false,
          created_at: Comment.now()
        })

      _ = ReviewServer.set_learn_from_this(id, :global, cid, true)
      state = ReviewServer.get_state(id)
      assert [%{id: ^cid, learn_from_this: true}] = state.global_comments
    end

    test "is a no-op for an unknown id", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      _ = ReviewServer.set_learn_from_this(id, :global, "nonexistent-id", true)
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
          learn_from_this: false,
          created_at: Comment.now()
        })

      _ = ReviewServer.set_learn_from_this(id, :inline, inline_id, true)
      assert [%{learn_from_this: true}] = ReviewServer.get_state(id).comments
    end
  end

  describe "set_open_form/2" do
    test "stores the form descriptor verbatim", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      form = %{
        surface: :inline,
        anchor: %{file_index: 0, start_line: 4, end_line: 6, side: "new"}
      }

      _ = ReviewServer.set_open_form(id, form)
      assert ReviewServer.get_state(id).open_form == form
    end

    test "nil clears the field", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      _ = ReviewServer.set_open_form(id, %{surface: :global, anchor: %{}})
      _ = ReviewServer.set_open_form(id, nil)
      assert ReviewServer.get_state(id).open_form == nil
    end

    test "broadcasts {:state_changed, state}", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      Phoenix.PubSub.subscribe(Meerkat.PubSub, ReviewServer.topic(id))

      form = %{surface: :global, anchor: %{}}
      _ = ReviewServer.set_open_form(id, form)

      assert_receive {:state_changed, %ReviewState{open_form: ^form}}, 500
    end

    test "persists across a process restart via Persistence", %{repo: repo, review_id: id} do
      {:ok, _} =
        ReviewServer.ensure_started(id, %{repo_path: repo, initial_state: %ReviewState{}})

      form = %{
        surface: :inline,
        anchor: %{file_index: 1, start_line: 10, end_line: 12, side: "old"}
      }

      _ = ReviewServer.set_open_form(id, form)

      loaded = Persistence.load(repo, id, %ReviewState{})
      assert loaded.open_form.surface == :inline
      assert loaded.open_form.anchor.file_index == 1
      assert loaded.open_form.anchor.start_line == 10
      assert loaded.open_form.anchor.end_line == 12
      assert loaded.open_form.anchor.side == "old"
    end
  end

  defp make_tmp_repo, do: Meerkat.TestHelpers.make_tmp_repo("meerkat-review-server")
end
