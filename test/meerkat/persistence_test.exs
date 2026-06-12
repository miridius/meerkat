defmodule Meerkat.PersistenceTest do
  use ExUnit.Case, async: true

  alias Meerkat.{Comment, Persistence, ReviewState}

  setup do
    repo = make_tmp_repo()
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, repo: repo, review_id: "abc1234567890def"}
  end

  describe "save/3 + load/3 round-trip" do
    test "comments survive", %{repo: repo, review_id: id} do
      comment = %{
        id: "c1",
        file_index: 0,
        start_line: 3,
        end_line: 5,
        side: :new,
        body: "tighten this",
        finding_type: :issue,
        learn_from_this: true,
        created_at: "2026-05-10T00:00:00Z"
      }

      state = %ReviewState{comments: [comment]}
      :ok = Persistence.save(repo, id, state)
      loaded = Persistence.load(repo, id, %ReviewState{})

      assert [reloaded] = loaded.comments
      # side is an atom in-memory; after JSON round-trip it lands
      # back as :new because keys: :atoms! exists. The value still
      # comes back as the string "new" though — Jason has no atom
      # value coercion. So assert on the string form here.
      assert reloaded.id == "c1"
      assert reloaded.body == "tighten this"
      assert reloaded.finding_type == "issue"
      assert reloaded.side == "new"
    end

    test "MapSet ↔ JSON array round-trip", %{repo: repo, review_id: id} do
      state = %ReviewState{
        approved_file_names: MapSet.new(["src/a.rs", "README.md"]),
        hidden_extensions: MapSet.new(["lock", "snap"])
      }

      :ok = Persistence.save(repo, id, state)
      loaded = Persistence.load(repo, id, %ReviewState{})

      assert MapSet.equal?(loaded.approved_file_names, state.approved_file_names)
      assert MapSet.equal?(loaded.hidden_extensions, state.hidden_extensions)
    end

    test "non-persistable fields stay at their defaults on load", %{repo: repo, review_id: id} do
      # `files`, `commit_message`, `pr`, etc. are derived from git at
      # mount time. We deliberately do NOT round-trip them.
      state = %ReviewState{
        comments: [],
        # not persistable — should NOT appear on the loaded shape
        commit_message: "this is in-memory only",
        files: [%{file_name: "a.rs", status: :added}]
      }

      :ok = Persistence.save(repo, id, state)
      reloaded = Persistence.load(repo, id, %ReviewState{commit_message: "from git"})

      assert reloaded.commit_message == "from git"
      assert reloaded.files == []
    end

    test "load/3 returns the given state unchanged when no save exists", %{repo: repo} do
      seed = %ReviewState{commit_message: "fresh"}
      assert Persistence.load(repo, "nonexistent_id_xyz", seed) == seed
    end

    test "load/3 tolerates a corrupt file", %{repo: repo, review_id: id} do
      path = Persistence.path_for(repo, id)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not valid json {")
      seed = %ReviewState{commit_message: "seed"}
      assert Persistence.load(repo, id, seed) == seed
    end

    test "open_form (inline) round-trips with atom surface + anchor keys",
         %{repo: repo, review_id: id} do
      form = %{
        surface: :inline,
        anchor: %{file_index: 0, start_line: 4, end_line: 6, side: "new"},
        edit_id: nil,
        initial_body: nil
      }

      state = %ReviewState{open_form: form}
      :ok = Persistence.save(repo, id, state)
      loaded = Persistence.load(repo, id, %ReviewState{})

      assert loaded.open_form.surface == :inline
      assert loaded.open_form.anchor.file_index == 0
      assert loaded.open_form.anchor.start_line == 4
      assert loaded.open_form.anchor.end_line == 6
      assert loaded.open_form.anchor.side == "new"
    end

    test "open_form nil stays nil through round-trip", %{repo: repo, review_id: id} do
      state = %ReviewState{open_form: nil}
      :ok = Persistence.save(repo, id, state)
      loaded = Persistence.load(repo, id, %ReviewState{})

      assert loaded.open_form == nil
    end

    test "open_form (edit) preserves edit_id + prefill metadata",
         %{repo: repo, review_id: id} do
      form = %{
        surface: :file,
        anchor: %{file_index: 2},
        edit_id: "abc-123",
        initial_body: "previous body",
        initial_finding_type: "suggestion",
        initial_learn_from_this: true
      }

      :ok = Persistence.save(repo, id, %ReviewState{open_form: form})
      loaded = Persistence.load(repo, id, %ReviewState{})

      assert loaded.open_form.surface == :file
      assert loaded.open_form.anchor.file_index == 2
      assert loaded.open_form.edit_id == "abc-123"
      assert loaded.open_form.initial_body == "previous body"
      assert loaded.open_form.initial_finding_type == "suggestion"
      assert loaded.open_form.initial_learn_from_this == true
    end

    test "delete/2 removes the file", %{repo: repo, review_id: id} do
      :ok = Persistence.save(repo, id, %ReviewState{})
      assert File.exists?(Persistence.path_for(repo, id))
      :ok = Persistence.delete(repo, id)
      refute File.exists?(Persistence.path_for(repo, id))
    end
  end

  describe "stale-snapshot guard via state_signature" do
    test "load with the same staged content rehydrates", %{repo: repo, review_id: id} do
      saved =
        %ReviewState{
          files: [
            %{file_name: "a.rs", effective_oid: "oid-a"},
            %{file_name: "b.rs", effective_oid: "oid-b"}
          ],
          global_comments: [global_comment_with(body: "keep me", finding_type: :issue)]
        }

      :ok = Persistence.save(repo, id, saved)

      reloaded =
        Persistence.load(repo, id, %ReviewState{
          files: [
            %{file_name: "a.rs", effective_oid: "oid-a"},
            %{file_name: "b.rs", effective_oid: "oid-b"}
          ]
        })

      assert [comment] = reloaded.global_comments
      assert comment.body == "keep me"
    end

    test "load with different staged content drops the snapshot + clears the file",
         %{repo: repo, review_id: id} do
      :ok =
        Persistence.save(repo, id, %ReviewState{
          files: [%{file_name: "a.rs", effective_oid: "oid-a"}],
          global_comments: [global_comment_with(body: "from previous session")]
        })

      assert File.exists?(Persistence.path_for(repo, id))

      reloaded =
        Persistence.load(repo, id, %ReviewState{
          files: [%{file_name: "a.rs", effective_oid: "oid-DIFFERENT"}]
        })

      assert reloaded.global_comments == []
      refute File.exists?(Persistence.path_for(repo, id))
    end

    test "cached state_signature on the input ReviewState is used over the live hash",
         %{repo: repo, review_id: id} do
      files = [%{file_name: "a.rs", effective_oid: "oid-a"}]
      live_sig = Persistence.state_signature(%ReviewState{files: files})

      # Stale cached sig stamped on the struct should still be used —
      # the whole point of the field is that callers (ReviewState.build/1)
      # compute it ONCE at mount and persist subsequent saves cheaply.
      stale_sig = "deadbeef" <> String.duplicate("0", 24)
      assert stale_sig != live_sig

      :ok =
        Persistence.save(repo, id, %ReviewState{
          files: files,
          state_signature: stale_sig,
          global_comments: [global_comment_with(body: "from cached-sig save")]
        })

      # The on-disk file should carry `stale_sig`, not `live_sig`.
      decoded = Persistence.path_for(repo, id) |> File.read!() |> Jason.decode!()
      assert decoded["state_signature"] == stale_sig
    end

    test "legacy snapshot without a state_signature still rehydrates",
         %{repo: repo, review_id: id} do
      path = Persistence.path_for(repo, id)
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          global_comments: [
            %{
              id: "c1",
              body: "legacy",
              finding_type: "issue",
              learn_from_this: false,
              created_at: "2026-01-01T00:00:00Z"
            }
          ]
        })
      )

      reloaded = Persistence.load(repo, id, %ReviewState{files: []})

      assert [comment] = reloaded.global_comments
      assert comment.body == "legacy"
    end

    test "state_signature is order-independent on files" do
      sig_a =
        Persistence.state_signature(%ReviewState{
          files: [
            %{file_name: "a.rs", effective_oid: "oid-a"},
            %{file_name: "b.rs", effective_oid: "oid-b"}
          ]
        })

      sig_b =
        Persistence.state_signature(%ReviewState{
          files: [
            %{file_name: "b.rs", effective_oid: "oid-b"},
            %{file_name: "a.rs", effective_oid: "oid-a"}
          ]
        })

      assert sig_a == sig_b
    end

    test "state_signature changes when content changes" do
      base = %ReviewState{files: [%{file_name: "a.rs", effective_oid: "oid-1"}]}
      bumped = %ReviewState{files: [%{file_name: "a.rs", effective_oid: "oid-2"}]}

      refute Persistence.state_signature(base) == Persistence.state_signature(bumped)
    end
  end

  describe "thought → follow_up migration on load" do
    test "migrates every surface", %{repo: repo, review_id: id} do
      thought_comment = fn body ->
        %{
          id: Comment.new_id(),
          file_index: 0,
          start_line: 1,
          end_line: 1,
          side: :new,
          body: body,
          finding_type: :thought,
          learn_from_this: false,
          created_at: Comment.now()
        }
      end

      state = %ReviewState{
        comments: [thought_comment.("inline")],
        file_comments: [thought_comment.("file")],
        global_comments: [thought_comment.("global")],
        commit_message_comments: [thought_comment.("commit")]
      }

      :ok = Persistence.save(repo, id, state)
      loaded = Persistence.load(repo, id, %ReviewState{})

      for list <- [
            loaded.comments,
            loaded.file_comments,
            loaded.global_comments,
            loaded.commit_message_comments
          ] do
        assert [%{finding_type: "follow_up"}] = list
      end
    end

    test "is idempotent on a second save→load cycle", %{repo: repo, review_id: id} do
      :ok =
        Persistence.save(repo, id, %ReviewState{
          global_comments: [global_comment_with(body: "x", finding_type: :thought)]
        })

      once = Persistence.load(repo, id, %ReviewState{})

      :ok = Persistence.save(repo, id, once)
      twice = Persistence.load(repo, id, %ReviewState{})

      assert [%{finding_type: "follow_up"}] = once.global_comments
      assert [%{finding_type: "follow_up"}] = twice.global_comments
    end
  end

  describe "atomic save" do
    test "intermediate temp file is cleaned up on success", %{repo: repo, review_id: id} do
      :ok = Persistence.save(repo, id, %ReviewState{global_comments: [global_comment()]})
      dir = Path.dirname(Persistence.path_for(repo, id))

      tmp_leftovers =
        File.ls!(dir)
        |> Enum.filter(&String.contains?(&1, ".tmp."))

      assert tmp_leftovers == []
    end
  end

  defp make_tmp_repo, do: Meerkat.TestHelpers.make_tmp_repo("meerkat-persistence-test")

  defp global_comment, do: global_comment_with([])

  defp global_comment_with(overrides) do
    Enum.into(overrides, %{
      id: Comment.new_id(),
      body: "test",
      finding_type: :issue,
      learn_from_this: false,
      created_at: Comment.now()
    })
  end
end
