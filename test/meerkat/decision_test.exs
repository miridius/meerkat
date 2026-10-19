defmodule Meerkat.DecisionTest do
  # async: false — Decision is a singleton GenServer, mounted by the
  # main supervisor. Meerkat.Case clears it around each test.
  use Meerkat.Case, async: false

  alias Meerkat.{Decision, Feedback, PendingAnswers, PendingQuestions, ReviewState}

  describe "submit/1 + await/0" do
    test "a second submit is refused and told which decision stands" do
      assert {:ok, {:approve, []}} = Decision.submit({:approve, []})

      assert {:already_decided, {:approve, []}} =
               Decision.submit({:reject, [reason: "too late"]})

      assert {:approve, []} = Decision.await()
      assert {:approve, []} = Decision.current()
    end

    test "await/0 blocks until submit/1 fires" do
      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      # Without a submit, the spawned process is still blocked.
      refute_receive {:awaited, _}, 50

      {:ok, _} = Decision.submit({:reject, [comments: ["nope"]]})
      assert_receive {:awaited, {:reject, [comments: ["nope"]]}}
    end

    test "current/0 is nil before submit, decision after" do
      assert is_nil(Decision.current())
      Decision.submit({:cancel, nil})
      assert {:cancel, nil} = Decision.current()
    end
  end

  describe "submit_review/3" do
    setup do
      repo = Meerkat.TestHelpers.make_git_repo("meerkat-review-obligations")
      on_exit(fn -> File.rm_rf!(repo) end)
      {:ok, repo: repo}
    end

    for {tag, mode} <- [reject: :rejection, approve_with_feedback: :approval_with_feedback] do
      test "#{tag} records questions before feedback is available, ignoring late decisions", %{
        repo: repo
      } do
        review = %ReviewState{
          global_comments: [
            %{
              finding_type: "question",
              body: "Why?",
              correct_instructions: false,
              lint_rule: false
            }
          ]
        }

        assert {:ok, {unquote(tag), payload}} = Decision.submit_review(unquote(tag), review, repo)
        assert payload == Feedback.format(review, unquote(mode))
        assert payload =~ "meerkat --answers"

        assert {:ok, [%{location: "global", question: "Why?"}]} =
                 PendingQuestions.unanswered(repo)

        assert {unquote(tag), ^payload} = Decision.await()

        assert {:already_decided, {unquote(tag), ^payload}} =
                 Decision.submit_review(:cancel, %ReviewState{}, repo)

        assert {:ok, [%{question: "Why?"}]} = PendingQuestions.unanswered(repo)
      end
    end

    test "accept side effects finish before the CLI wakes", %{repo: repo} do
      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      # on_accept runs inside the Decision server, which it blocks until told to finish.
      on_accept = fn ->
        send(parent, {:accepting, self()})
        receive do: (:finish -> :ok)
      end

      spawn_link(fn ->
        send(
          parent,
          {:submitted, Decision.submit_review(:approve, %ReviewState{}, repo, on_accept)}
        )
      end)

      assert_receive {:accepting, server}
      refute_receive {:awaited, _}, 50
      send(server, :finish)
      assert_receive {:submitted, {:ok, {:approve, ""}}}
      assert_receive {:awaited, {:approve, ""}}
    end

    test "unrecorded questions are never delivered as a decision", %{repo: repo} do
      File.write!(Path.dirname(PendingQuestions.path_for(repo)), "not a directory")
      parent = self()
      spawn(fn -> send(parent, {:awaited, catch_exit(Decision.await())}) end)
      # Let the waiter reach the server before the submit crashes it.
      refute_receive {:awaited, _}, 50

      review = %ReviewState{
        global_comments: [
          %{finding_type: :question, body: "Why?", correct_instructions: false, lint_rule: false}
        ]
      }

      ExUnit.CaptureLog.capture_log(fn ->
        assert {{%File.Error{action: "record owed questions"}, _}, _} =
                 catch_exit(
                   Decision.submit_review(:reject, review, repo, fn -> send(parent, :accepted) end)
                 )
      end)

      assert_receive {:awaited, {{%File.Error{}, _}, _}}
      refute_received :accepted
    end

    test "non-page decision tags cannot record a decision or erase owed questions", %{repo: repo} do
      questions = [%{location: "global", question: "Still owed?"}]
      :ok = PendingQuestions.replace(repo, questions)

      for tag <- [:timeout, :unknown] do
        assert_raise FunctionClauseError, fn ->
          Decision.submit_review(tag, %ReviewState{}, repo)
        end

        assert Decision.current() == nil
        assert {:ok, ^questions} = PendingQuestions.unanswered(repo)
      end
    end

    for tag <- [:approve, :cancel] do
      test "#{tag} wipes the previous round's obligation without owing the round's comments", %{
        repo: repo
      } do
        :ok =
          PendingQuestions.replace(repo, [%{location: "global", question: "Already answered?"}])

        review = %ReviewState{
          global_comments: [
            %{
              finding_type: :question,
              body: "Not delivered?",
              correct_instructions: false,
              lint_rule: false
            }
          ]
        }

        assert {:ok, {unquote(tag), ""}} = Decision.submit_review(unquote(tag), review, repo)
        assert {:ok, []} = PendingQuestions.unanswered(repo)
      end
    end

    test "an answered round's obligations are replaced before its answer banner is cleared", %{
      repo: repo
    } do
      :ok = PendingQuestions.replace(repo, [%{location: "global", question: "Before?"}])

      {:ok, 1} =
        PendingAnswers.save(
          repo,
          ~s({"answers":[{"location":"global","question":"Before?","answer":"Yes."}]})
        )

      review = %ReviewState{
        global_comments: [
          %{
            finding_type: :question,
            body: "After?",
            correct_instructions: false,
            lint_rule: false
          }
        ]
      }

      assert {:ok, _} = Decision.submit_review(:reject, review, repo)
      PendingAnswers.clear(repo)

      assert {:ok, [%{location: "global", question: "After?"}]} =
               PendingQuestions.unanswered(repo)
    end
  end

  describe "the review deadline" do
    setup do
      repo = Meerkat.TestHelpers.make_git_repo("meerkat-decision-deadline")
      previous_repo = Application.fetch_env(:meerkat, :repo_path)
      Application.put_env(:meerkat, :repo_path, repo)

      on_exit(fn ->
        case previous_repo do
          {:ok, value} -> Application.put_env(:meerkat, :repo_path, value)
          :error -> Application.delete_env(:meerkat, :repo_path)
        end

        File.rm_rf!(repo)
      end)

      Application.put_env(:meerkat, :deadline_check_ms, 5)
      previous_action = System.get_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT")
      System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", "true")

      on_exit(fn ->
        Application.delete_env(:meerkat, :deadline_check_ms)
        Application.delete_env(:meerkat, :review_deadline_ms)
        System.delete_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT")

        if previous_action,
          do: System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", previous_action)
      end)

      :ok
    end

    test "a deadline already past leaves the review open when auto-approve is off" do
      System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", "false")
      Application.put_env(:meerkat, :review_deadline_ms, System.system_time(:millisecond) - 1)
      Decision.reset()

      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      # Outlives several deadline checks (`deadline_check_ms` is 5ms here).
      refute_receive {:awaited, _}, 100
      assert {:ok, {:approve, ""}} = Decision.submit({:approve, ""})
      assert_receive {:awaited, {:approve, ""}}
    end

    test "an overdue review left open keeps its deadline directory recent" do
      run_dir = overdue_review()
      backdated_s = System.system_time(:second) - 3600
      File.touch!(run_dir, backdated_s)

      Decision.reset()

      assert Meerkat.TestHelpers.eventually(fn ->
               File.stat!(run_dir, time: :posix).mtime > backdated_s
             end)
    end

    test "an overdue review's deadline checks start no subprocess" do
      overdue_review()
      decision = Process.whereis(Decision)
      :erlang.trace(:new_ports, true, [:ports])

      Decision.reset()
      Process.sleep(100)
      :sys.get_state(Decision)
      :erlang.trace(:new_ports, false, [:ports])

      refute_received {:trace, _port, :open, ^decision, _command}
    end

    test "a deadline already past ends the review without anyone clicking" do
      Application.put_env(:meerkat, :review_deadline_ms, System.system_time(:millisecond) - 1)
      Decision.reset()

      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      assert_receive {:awaited, {:timeout, ""}}
    end

    test "a deadline still ahead leaves the review open" do
      Application.put_env(
        :meerkat,
        :review_deadline_ms,
        System.system_time(:millisecond) + 60_000
      )

      Decision.reset()

      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      refute_receive {:awaited, _}, 100
    end

    test "a disabled deadline (nil) never auto-approves, however long the review runs" do
      # cli.ex arms `review_deadline_ms` only when `Timeout.deadline_ms/2`
      # returns one; disabled, it is nil and no tick ever fires.
      Application.put_env(:meerkat, :review_deadline_ms, nil)
      Decision.reset()

      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)

      # Outlives several deadline checks (`deadline_check_ms` is 5ms here).
      refute_receive {:awaited, {:timeout, _}}, 100
    end

    test "a click before the deadline is the decision the review keeps" do
      Application.put_env(
        :meerkat,
        :review_deadline_ms,
        System.system_time(:millisecond) + 60_000
      )

      Decision.reset()
      assert {:ok, {:approve, ""}} = Decision.submit({:approve, ""})

      Process.sleep(30)

      assert {:approve, ""} = Decision.current()
    end

    test "a click after the deadline is refused and told the review timed out" do
      Application.put_env(:meerkat, :review_deadline_ms, System.system_time(:millisecond) - 1)
      Decision.reset()

      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)
      assert_receive {:awaited, {:timeout, _}}

      assert {:already_decided, {:timeout, _}} =
               Decision.submit({:reject, "please fix the thing"})

      assert {:timeout, _} = Decision.current()
    end
  end

  defp overdue_review do
    repo = Meerkat.TestHelpers.make_tmp_repo("meerkat-decision")
    meerkat_dir = Path.join([repo, ".git", "meerkat-precommit"])
    Application.put_env(:meerkat, :repo_path, repo)
    # Match production: Meerkat.CLI.start_endpoint! caches :meerkat_dir in
    # application env. Without it, each 5 ms deadline check runs two `git
    # rev-parse` subprocesses in the singleton Decision GenServer; under
    # load one took over 5 s and the on_exit reset timed out. The callers
    # setup below caches it for the same reason.
    Application.put_env(:meerkat, :meerkat_dir, meerkat_dir)

    on_exit(fn ->
      Application.delete_env(:meerkat, :repo_path)
      Application.delete_env(:meerkat, :meerkat_dir)
      File.rm_rf(repo)
    end)

    System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", "false")
    Meerkat.Timeout.deadline_ms(repo, "abc123")
    Application.put_env(:meerkat, :review_deadline_ms, System.system_time(:millisecond) - 1)
    Path.join([meerkat_dir, "deadlines", "unkeyed"])
  end

  describe "callers" do
    import Meerkat.TestHelpers

    setup do
      repo = make_tmp_repo("meerkat-decision-callers")
      Application.put_env(:meerkat, :repo_path, repo)
      Application.put_env(:meerkat, :meerkat_dir, Path.join([repo, ".git", "meerkat-precommit"]))
      Application.put_env(:meerkat, :review_id, "abc123")
      Application.put_env(:meerkat, :deadline_check_ms, 5)
      previous = System.get_env("MEERKAT_REVIEW_TIMEOUT")
      previous_action = System.get_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT")
      System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", "true")

      on_exit(fn ->
        if previous,
          do: System.put_env("MEERKAT_REVIEW_TIMEOUT", previous),
          else: System.delete_env("MEERKAT_REVIEW_TIMEOUT")

        if previous_action,
          do: System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", previous_action),
          else: System.delete_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT")

        Enum.each(
          [:repo_path, :meerkat_dir, :review_id, :deadline_check_ms, :review_deadline_ms],
          &Application.delete_env(:meerkat, &1)
        )

        File.rm_rf(repo)
      end)

      Application.put_env(:meerkat, :review_deadline_ms, nil)
      Decision.reset()
      %{repo: repo}
    end

    defp spawn_caller(run_id) do
      parent = self()

      pid =
        spawn(fn ->
          send(parent, {:attached, self(), Decision.attach(run_id)})

          receive do
            {:meerkat_outcome, outcome} -> send(parent, {:outcome, self(), outcome})
            {:meerkat_displaced, text} -> send(parent, {:displaced, self(), text})
          end

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:attached, ^pid, reply}
      {pid, reply}
    end

    test "an attached caller is sent the outcome once it is published" do
      {pid, reply} = spawn_caller("run-a")
      assert reply == {:ok, nil}

      :ok = Decision.publish({1, "feedback\n"})
      assert_receive {:outcome, ^pid, {1, "feedback\n"}}
    end

    test "a caller for another run displaces the one attached before it" do
      {first, _} = spawn_caller("run-a")
      {second, _} = spawn_caller("run-b")

      assert_receive {:displaced, ^first,
                      "meerkat: a later invocation of this review took it over — aborting."}

      :ok = Decision.publish({0, "approved\n"})
      assert_receive {:outcome, ^second, {0, "approved\n"}}
      refute_receive {:outcome, ^first, _}, 100
    end

    test "a caller reattaching for its own run displaces nobody" do
      {first, _} = spawn_caller("run-a")
      {_again, _} = spawn_caller("run-a")
      refute_receive {:displaced, ^first, _}, 100
    end

    test "replacing the review tells every attached caller why, stops tracking them and disarms the deadline" do
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "600")
      {first, _} = spawn_caller("run-a")
      {again, _} = spawn_caller("run-a")

      assert Enum.sort(Decision.replace("changed")) == Enum.sort([first, again])
      assert_receive {:displaced, ^first, "changed"}
      assert_receive {:displaced, ^again, "changed"}
      assert :sys.get_state(Decision).callers == %{}
      assert Application.get_env(:meerkat, :review_deadline_ms) == nil
    end

    test "an outcome published with nobody attached is held for the next caller" do
      :ok = Decision.publish({0, "approved\n"})

      {_pid, reply} = spawn_caller("run-b")
      assert reply == {:ok, {0, "approved\n"}}
    end

    test "a delivery wakes the CLI with the delivering run, and later callers are turned away" do
      parent = self()
      spawn_link(fn -> send(parent, {:delivered_to, Decision.await_delivery()}) end)

      assert Decision.delivered("run-c") == {:error, :no_outcome}
      refute_receive {:delivered_to, _}, 50

      :ok = Decision.publish({0, "approved\n"})
      assert Decision.delivered("run-c") == :ok
      assert_receive {:delivered_to, "run-c"}
      assert Decision.attach("run-d") == :closing
    end

    test "a delivery reported before the CLI waits for one is handed to it when it does" do
      :ok = Decision.publish({0, "approved\n"})
      :ok = Decision.delivered("run-e")
      assert Decision.await_delivery() == "run-e"
    end

    test "an outcome without an integer exit code and a text is refused" do
      for outcome <- [{"1", "feedback\n"}, {1, :feedback}] do
        assert_raise FunctionClauseError, fn -> Decision.publish(outcome) end
      end
    end

    test "the deadline runs only while a caller is attached" do
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "600")
      {pid, _} = spawn_caller("run-e")

      armed = Application.get_env(:meerkat, :review_deadline_ms)
      assert is_integer(armed), "attaching arms the deadline"
      assert armed > System.system_time(:millisecond) + 590_000

      Process.exit(pid, :kill)

      assert eventually(fn -> is_nil(Application.get_env(:meerkat, :review_deadline_ms)) end),
             "the last caller leaving disarms the deadline"
    end

    test "a later run's deadline starts from its own attach, however long an earlier run waited",
         %{repo: repo} do
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "600")
      {first, _} = spawn_caller("run-a")
      anchor = Path.join([repo, ".git", "meerkat-precommit", "deadlines", "run-a", "abc123"])
      File.write!(anchor, Integer.to_string(System.system_time(:millisecond) - 3_600_000))
      Process.exit(first, :kill)

      {_second, _} = spawn_caller("run-b")

      assert Application.get_env(:meerkat, :review_deadline_ms) >
               System.system_time(:millisecond) + 590_000
    end

    test "a caller reattaching within one deadline check leaves a single check running" do
      Application.put_env(:meerkat, :deadline_check_ms, 200)
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "600")
      {first, _} = spawn_caller("run-i")
      Process.exit(first, :kill)
      assert eventually(fn -> is_nil(Application.get_env(:meerkat, :review_deadline_ms)) end)

      {_again, _} = spawn_caller("run-j")
      decision = Process.whereis(Decision)
      :erlang.trace(decision, true, [:receive])
      Process.sleep(1000)
      :erlang.trace(decision, false, [:receive])

      checks =
        Stream.repeatedly(fn ->
          receive do
            {:trace, ^decision, :receive, :check_deadline} -> :check
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)
        |> length()

      assert checks <= 6, "one check every 200 ms over 1 s, not #{checks}"
    end

    test "a deadline armed by an attach ends the review once it passes" do
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "1")
      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)
      {_pid, _} = spawn_caller("run-f")

      assert_receive {:awaited, {:timeout, _}}
    end

    test "an overdue review left open keeps its attached caller's deadline directory recent",
         %{repo: repo} do
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "1")
      System.put_env("MEERKAT_AUTO_APPROVE_ON_TIMEOUT", "false")
      {_pid, _} = spawn_caller("run-h")
      run_dir = Path.join([repo, ".git", "meerkat-precommit", "deadlines", "run-h"])
      backdated_s = System.system_time(:second) - 3600
      File.touch!(run_dir, backdated_s)

      assert eventually(fn -> File.stat!(run_dir, time: :posix).mtime > backdated_s end)
    end

    test "a review whose caller has left does not time out" do
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "1")
      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)
      {pid, _} = spawn_caller("run-g")
      Process.exit(pid, :kill)

      refute_receive {:awaited, _}, 1500
    end
  end

  describe "ending a review nothing waits on" do
    import Meerkat.TestHelpers

    alias Meerkat.{Comment, ReviewServer}

    @env_keys [
      :repo_path,
      :review_id,
      :review_state,
      :serve_dir,
      :caller_check_ms,
      :review_deadline_ms
    ]

    setup do
      repo = make_tmp_repo("meerkat-decision-ending")
      serve_dir = Path.join(repo, "run")
      File.mkdir_p!(serve_dir)
      review_id = "ending_#{System.unique_integer([:positive])}"
      Application.put_env(:meerkat, :repo_path, repo)
      Application.put_env(:meerkat, :review_id, review_id)
      Application.put_env(:meerkat, :review_state, %ReviewState{})
      Application.put_env(:meerkat, :serve_dir, serve_dir)
      Application.put_env(:meerkat, :caller_check_ms, 5)

      on_exit(fn ->
        case Registry.lookup(Meerkat.ReviewRegistry, review_id) do
          [{pid, _}] -> DynamicSupervisor.terminate_child(Meerkat.ReviewServerSup, pid)
          [] -> :ok
        end

        Enum.each(@env_keys, &Application.delete_env(:meerkat, &1))
        Decision.reset()
        File.rm_rf(repo)
      end)

      Decision.reset()
      Phoenix.PubSub.subscribe(Meerkat.PubSub, Decision.decision_topic())
      %{repo: repo, serve_dir: serve_dir, review_id: review_id}
    end

    defp await_in_background do
      parent = self()
      spawn_link(fn -> send(parent, {:awaited, Decision.await()}) end)
    end

    defp start_review(review_id, repo) do
      {:ok, _} =
        ReviewServer.ensure_started(review_id, %{repo_path: repo, initial_state: %ReviewState{}})
    end

    defp comment do
      %{
        id: Comment.new_id(),
        body: "keep me",
        finding_type: :issue,
        correct_instructions: false,
        lint_rule: false,
        created_at: Comment.now()
      }
    end

    # The pid of a shell that has exited.
    defp exited_pid do
      {out, 0} = System.cmd("/bin/sh", ["-c", "echo $$"])
      String.trim(out)
    end

    test "a review with no comments ends once its last caller detaches, and turns later callers away" do
      await_in_background()
      {first, _} = spawn_caller("run-a")
      {second, _} = spawn_caller("run-a")
      Process.exit(first, :kill)
      refute_receive {:awaited, _}, 100

      Process.exit(second, :kill)
      assert_receive {:awaited, {:ended, ""}}
      assert_receive {:meerkat_decision, {:ended, ""}}
      assert Decision.attach("run-b") == :closing
      assert {:already_decided, {:ended, ""}} = Decision.submit({:approve, ""})
    end

    test "a review with a saved comment stays open, even once its comments are deleted", %{
      repo: repo,
      review_id: review_id
    } do
      start_review(review_id, repo)
      %{global_comments: [%{id: id}]} = ReviewServer.add_comment(review_id, :global, comment())
      await_in_background()
      {pid, _} = spawn_caller("run-a")
      Process.exit(pid, :kill)
      refute_receive {:awaited, _}, 200

      ReviewServer.remove_comment(review_id, :global, id)
      refute_receive {:awaited, _}, 200
      assert Decision.current() == nil
    end

    test "comments saved by an earlier BEAM keep the review open before any tab starts its server",
         %{repo: repo, review_id: review_id} do
      start_review(review_id, repo)
      ReviewServer.add_comment(review_id, :global, comment())
      [{server, _}] = Registry.lookup(Meerkat.ReviewRegistry, review_id)
      :ok = DynamicSupervisor.terminate_child(Meerkat.ReviewServerSup, server)

      await_in_background()
      {pid, _} = spawn_caller("run-a")
      Process.exit(pid, :kill)
      refute_receive {:awaited, _}, 200
    end

    test "a review with an open comment form stays open", %{repo: repo, review_id: review_id} do
      start_review(review_id, repo)
      ReviewServer.open_form(review_id, %{surface: :global, anchor: %{}})
      await_in_background()
      {pid, _} = spawn_caller("run-a")
      Process.exit(pid, :kill)
      refute_receive {:awaited, _}, 200
    end

    test "a decision made before the caller detaches stands" do
      {pid, _} = spawn_caller("run-a")
      {:ok, _} = Decision.submit({:approve, ""})
      Process.exit(pid, :kill)
      refute_receive {:meerkat_decision, {:ended, _}}, 200
      assert Decision.current() == {:approve, ""}
    end

    test "a caller that died before attaching ends the review", %{serve_dir: serve_dir} do
      File.write!(Path.join(serve_dir, "caller"), exited_pid())
      await_in_background()
      # Well inside the default second, so the configured 5 ms is what runs.
      assert_receive {:awaited, {:ended, ""}}, 500
    end

    test "the recorded caller is checked once a second unless configured otherwise" do
      assert Decision.caller_check_ms() == 5
      Application.delete_env(:meerkat, :caller_check_ms)
      assert Decision.caller_check_ms() == 1_000
    end

    test "without a launcher, a review stays open when its caller detaches" do
      Application.delete_env(:meerkat, :serve_dir)
      await_in_background()
      {pid, _} = spawn_caller("run-a")
      Process.exit(pid, :kill)
      # Long enough for a judgement, which starts the review's server, to land.
      refute_receive {:awaited, _}, 1_000
    end

    test "a caller leaving while another stays attached keeps the deadline armed" do
      System.put_env("MEERKAT_REVIEW_TIMEOUT", "600")
      on_exit(fn -> System.delete_env("MEERKAT_REVIEW_TIMEOUT") end)
      Phoenix.PubSub.subscribe(Meerkat.PubSub, Decision.deadline_topic())
      {first, _} = spawn_caller("run-a")
      {second, _} = spawn_caller("run-a")
      Process.exit(first, :kill)
      refute_receive {:meerkat_deadline, nil}, 200

      Process.exit(second, :kill)
      assert_receive {:meerkat_deadline, nil}
    end

    test "a caller check arriving once a caller is attached is dropped silently", %{
      serve_dir: serve_dir,
      review_id: review_id
    } do
      {_pid, _} = spawn_caller("run-a")
      File.write!(Path.join(serve_dir, "caller"), exited_pid())

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(Decision, :check_caller)
          :sys.get_state(Decision)
        end)

      assert log == ""
      # Judging would have started the review's server.
      Process.sleep(100)
      assert Registry.lookup(Meerkat.ReviewRegistry, review_id) == []
    end

    test "end_if_unused/1 says whether it ended the review", %{repo: repo, review_id: review_id} do
      start_review(review_id, repo)
      %{global_comments: [%{id: id}]} = ReviewServer.add_comment(review_id, :global, comment())
      assert ReviewServer.end_if_unused(review_id) == :kept

      ReviewServer.remove_comment(review_id, :global, id)
      assert ReviewServer.end_if_unused(review_id) == :ended
      assert Decision.current() == {:ended, ""}
    end

    test "a caller still alive before attaching keeps the review waiting until it detaches", %{
      serve_dir: serve_dir
    } do
      port =
        Port.open({:spawn_executable, "/bin/sh"}, [
          :binary,
          args: ["-c", "sleep 30; true", "meerkat-attach"]
        ])

      {:os_pid, caller} = Port.info(port, :os_pid)
      on_exit(fn -> System.cmd("kill", [to_string(caller)], stderr_to_stdout: true) end)
      File.write!(Path.join(serve_dir, "caller"), "#{caller}\n")
      await_in_background()
      refute_receive {:awaited, _}, 100

      # Once a caller attaches, the recorded pid is no longer what is checked.
      {pid, _} = spawn_caller("run-a")
      File.write!(Path.join(serve_dir, "caller"), exited_pid())
      refute_receive {:awaited, _}, 100

      Process.exit(pid, :kill)
      assert_receive {:awaited, {:ended, ""}}
    end

    test "end_unattended/0 keeps a review with an attached caller or a decision" do
      {_pid, _} = spawn_caller("run-a")
      assert Decision.end_unattended() == :kept
      assert Decision.current() == nil

      Decision.reset()
      {:ok, _} = Decision.submit({:cancel, ""})
      assert Decision.end_unattended() == :kept
      assert Decision.current() == {:cancel, ""}
    end
  end

  describe "reset/0" do
    test "clears a submitted decision back to nil" do
      Decision.submit({:approve, []})
      assert {:approve, []} = Decision.current()

      assert :ok = Decision.reset()
      assert is_nil(Decision.current())
      # A fresh decision can be submitted after reset.
      Decision.submit({:reject, []})
      assert {:reject, []} = Decision.current()
    end
  end

  describe "stray messages" do
    test "an unexpected message is logged and the decision survives it" do
      pid = Process.whereis(Decision)
      {:ok, _} = Decision.submit({:approve, ""})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(Decision, :not_a_decision_message)
          :sys.get_state(Decision)
        end)

      assert log =~ "Meerkat.Decision: unexpected message :not_a_decision_message"
      assert Process.whereis(Decision) == pid
      assert Decision.current() == {:approve, ""}
    end

    test "a deadline check arriving after the decision is dropped silently" do
      {:ok, _} = Decision.submit({:approve, ""})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(Decision, :check_deadline)
          :sys.get_state(Decision)
        end)

      assert log == ""
      assert Decision.current() == {:approve, ""}
    end
  end
end
