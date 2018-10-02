# frozen_string_literal: true
require_relative '../test_helper'
require 'ar_multi_threaded_transactional_tests'

SingleCov.covered! uncovered: 9

describe JobExecution do
  include GitRepoTestHelper

  def execute_job(branch = 'master', on_finish: nil, on_start: nil, **options)
    execution = JobExecution.new(branch, job, options)
    execution.on_finish(&on_finish) if on_finish.present?
    execution.on_start(&on_start) if on_start.present?
    execution.send(:run)
  end

  def last_line_of_output
    job.output.to_s.split("\n").last.strip
  end

  let(:repo_dir) { File.join(GitRepository.cached_repos_dir, project.repository_directory) }
  let(:pod1) { deploy_groups(:pod1) }
  let(:pod2) { deploy_groups(:pod2) }
  let(:deploy_group_hack) { DeployGroup.create!(name: ';|sudo make-sandwich /', environment: pod1.environment) }
  let(:project) { Project.create!(name: 'duck', repository_url: repo_temp_dir) }
  let(:stage) { Stage.create!(name: 'stage4', project: project, deploy_groups: [pod1, pod2, deploy_group_hack]) }
  let(:stage_no_groups) { Stage.create!(name: 'stage_no_groups', project: project, deploy_groups: []) }
  let(:user) { users(:admin) }
  let(:job) { project.jobs.create!(command: 'cat foo', user: user, project: project) }
  let(:execution) { JobExecution.new('master', job) }
  let(:deploy) { Deploy.create!(stage: stage, job: job, reference: 'master', project: project) }

  with_full_job_execution

  before do
    execute_on_remote_repo "git tag v1"
    Project.any_instance.stubs(:valid_repository_url).returns(true)
    user.name = 'John Doe'
    user.email = 'jdoe@test.com'
    project.repository.send(:clone!)
    job.deploy = deploy
    freeze_time
  end

  after do
    FileUtils.rm_rf(repo_dir)
    project.repository.clean!
  end

  it "clones the project's repository if it's not already cloned" do
    execution.send(:run)
    assert File.directory?(repo_dir)
  end

  it 'checks out the specified commit' do
    execute_on_remote_repo <<-SHELL
      git tag foobar
      echo giraffe > foo
      git add foo
      git commit -m "second commit"
    SHELL

    execute_job 'foobar'

    assert_equal '[04:05:06] monkey', last_line_of_output
  end

  it 'does not fail with nil ENV vars' do
    User.any_instance.expects(:name).at_least_once.returns(nil)
    execution.send(:run)
  end

  it 'checks out the specified remote branch' do
    execute_on_remote_repo <<-SHELL
      git checkout -b armageddon
      echo lion > foo
      git add foo
      git commit -m "branch commit"
      git checkout master
    SHELL

    execute_job 'armageddon'

    assert job.succeeded?
    assert_equal '[04:05:06] lion', last_line_of_output
  end

  it 'records the commit properly when given an annotated tag' do
    execute_on_remote_repo <<-SHELL
      git checkout -b mantis_shrimp
      echo mantis shrimp > foo
      git add foo
      git commit -m "commit"
      git tag -a annotated_tag -m "annotation"
      git checkout master
    SHELL

    branch = File.join(repo_temp_dir, '.git', 'refs', 'heads', 'mantis_shrimp')
    commit = File.read(branch).strip

    execute_job 'annotated_tag'

    assert job.succeeded?
    assert_equal '[04:05:06] mantis shrimp', last_line_of_output
    assert job.commit.present?, "Expected #{job} to record the commit"
    assert_equal commit, job.commit
    assert_includes 'annotated_tag', job.tag
  end

  it "updates the branch to match what's in the remote repository" do
    execute_on_remote_repo <<-SHELL
      git checkout -b safari
      echo tiger > foo
      git add foo
      git commit -m "commit"
      git checkout master
    SHELL

    execute_job 'safari'

    assert_equal '[04:05:06] tiger', last_line_of_output

    # pretend we are in a new request
    project.repository.instance_variable_set(:@mirror_current, nil)

    execute_on_remote_repo <<-SHELL
      git checkout safari
      echo zebra > foo
      git add foo
      git commit -m "second commit"
      git checkout master
    SHELL

    execute_job 'safari'

    assert_equal '[04:05:06] zebra', last_line_of_output
  end

  it "tests additional exports hook" do
    freeze_time
    job.update(command: 'env | sort')
    Samson::Hooks.with_callback(
      :job_additional_vars,
      ->(_job) { {ADDITIONAL_EXPORT1: "yes"} },
      ->(_job) { {ADDITIONAL_EXPORT2: "yes"} }
    ) do
      execute_job
      lines = job.output.split "\n"
      lines.must_include "[04:05:06] ADDITIONAL_EXPORT1=yes"
      lines.must_include "[04:05:06] ADDITIONAL_EXPORT2=yes"
    end
  end

  it "exports deploy information as environment variables" do
    job.update(command: 'env | sort')
    execute_job 'master', env: {FOO: 'bar'}
    lines = job.output.split "\n"
    lines.must_include "[04:05:06] DEPLOY_ID=#{deploy.id}"
    lines.must_include "[04:05:06] DEPLOY_URL=#{deploy.url}"
    lines.must_include "[04:05:06] DEPLOYER=jdoe@test.com"
    lines.must_include "[04:05:06] DEPLOYER_EMAIL=jdoe@test.com"
    lines.must_include "[04:05:06] DEPLOYER_NAME=John Doe"
    lines.must_include "[04:05:06] REFERENCE=master"
    lines.must_include "[04:05:06] REVISION=#{job.commit}"
    lines.must_include "[04:05:06] TAG=v1"
    lines.must_include "[04:05:06] FOO=bar"
  end

  it 'works without a deploy' do
    job_without_deploy = project.jobs.create!(command: 'cat foo', user: user, project: project)
    execution = JobExecution.new('master', job_without_deploy)
    execution.send(:run)
    # if you like, pretend there's a wont_raise assertion here
    # this is to make sure we don't add a hard dependency on having a deploy
  end

  it 'does not export deploy_group information if no deploy groups present' do
    job.update(command: 'env | sort')
    deploy.stub :stage, stage_no_groups do
      execute_job
      job.output.wont_include "DEPLOY_GROUPS"
    end
  end

  it 'maintains a cache of build artifacts between runs' do
    job.command = 'echo hello > $CACHE_DIR/foo'
    execute_job

    job.command = 'cat $CACHE_DIR/foo'
    execute_job
    assert_equal '[04:05:06] hello', last_line_of_output
  end

  it 'removes the job from the queue when done' do
    execution = JobExecution.new('master', job)
    JobQueue.perform_later(execution)

    JobQueue.find_by_id(execution.id).wont_be_nil

    assert JobQueue.wait(execution.id)

    JobQueue.find_by_id(execution.id).must_be_nil
  end

  it 'calls on complete subscribers after finishing' do
    called_subscriber = false
    execute_job('master', on_finish: -> { called_subscriber = true })
    assert_equal true, called_subscriber
  end

  it 'calls on start subscribers before finishing' do
    called_subscriber = false
    execute_job('master', on_start: -> { called_subscriber = true })
    assert_equal true, called_subscriber
  end

  it 'fails when on start callback fails' do
    execute_job('master', on_start: -> { raise(Samson::Hooks::UserError, 'failure') })

    job.output.must_include 'failed'
    assert_equal 'errored', job.status
  end

  it 'outputs start / stop events' do
    execution = JobExecution.new('master', job)
    output = execution.output
    execution.send(:run)

    assert output.include?(:started, '') # cannot use must_include
    assert output.include?(:finished, '')
  end

  it 'calls subscribers after queued stoppage' do
    called_subscriber = false

    execution = JobExecution.new('master', job)
    execution.on_finish { called_subscriber = true }
    execution.perform
    execution.cancel

    assert called_subscriber
  end

  it 'saves job output before calling subscriber' do
    output = nil
    execute_job('master', on_finish: -> { output = job.output })
    assert_equal '[04:05:06] monkey', output.split("\n").last.strip
  end

  it 'errors if job setup fails' do
    execute_job('nope')
    assert_equal 'errored', job.status
    job.output.to_s.must_include "Could not find commit for nope"
  end

  it 'errors if job commit resultion fails, but checkout works' do
    GitRepository.any_instance.expects(:commit_from_ref).returns nil
    execute_job('master')
    assert_equal 'errored', job.status
    job.output.to_s.must_include "Could not find commit for master"
  end

  it 'cannot setup project if project is locked' do
    project.repository.expects(:setup).never
    begin
      MultiLock.send(:try_lock, project.id, 'me')
      execution.send(:run)
    ensure
      MultiLock.send(:unlock, project.id)
    end
  end

  it 'can access secrets' do
    id = "global/#{project.permalink}/global/bar"
    create_secret id
    job.update(command: "echo 'secret://bar'")
    execute_job("master")
    assert_equal '[04:05:06] MY-SECRET', last_line_of_output
  end

  it 'does not add the job to the queue when JobExecution is disabled' do
    JobQueue.enabled = false

    execution = JobExecution.new('master', job)
    JobQueue.perform_later(execution)

    JobQueue.find_by_id(execution.id).must_be_nil
    JobQueue.queued?(execution.id).must_be_nil
    JobQueue.executing?(execution.id).must_be_nil
  end

  it 'can run with a block' do
    x = :not_called
    execution = JobExecution.new('master', job) { x = :called }
    assert execution.send(:run)
    x.must_equal :called
  end

  it "reports to statsd" do
    Samson.statsd.expects(:histogram).
      with('execute_shell.time', anything, tags: ['project:duck', 'stage:stage4', 'production:false'])
    assert execute_job("master")
  end

  describe "builds_in_environment" do
    let(:build) { builds(:docker_build) }

    before do
      stage.update_column(:builds_in_environment, true)
      Samson::BuildFinder.any_instance.expects(:ensure_successful_builds).returns([build])
    end

    it "makes builds available via env" do
      JobExecution.new('master', job).send(:run)
      job.output.must_include "export BUILD_FROM_Dockerfile=docker-registry.example.com"
    end

    it "makes builds without dockerfile available via env" do
      build.update_columns(dockerfile: nil, image_name: 'foo')
      JobExecution.new('master', job).send(:run)
      job.output.must_include "export BUILD_FROM_foo=docker-registry.example.com"
    end
  end

  describe "kubernetes" do
    before { stage.update_column :kubernetes, true }

    it "does the execution with the kubernetes executor" do
      Kubernetes::DeployExecutor.any_instance.expects(:execute).returns true
      execute_job("master")
    end

    it "does not clone the repo" do
      GitRepository.any_instance.expects(:checkout_workspace).never
      execute_job("master")
    end
  end

  describe "#perform" do
    def perform
      execution.perform
    end

    def with_hidden_errors
      Rails.application.config.consider_all_requests_local = false
      yield
    ensure
      Rails.application.config.consider_all_requests_local = true
    end

    let(:execution) { JobExecution.new('master', job) }
    let(:model_file) { 'app/models/job_execution.rb' }

    it "runs a job" do
      perform
      execution.output.to_s.must_include "cat foo"
      job.reload.output.must_include "cat foo"
    end

    it "records exceptions to output" do
      ErrorNotifier.expects(:notify)
      job.expects(:running!).raises("Oh boy")
      perform
      execution.output.to_s.must_include "JobExecution failed: Oh boy"
      job.reload.output.must_include "JobExecution failed: Oh boy" # shows error message
      job.reload.output.must_include model_file # shows important backtrace
      job.reload.output.wont_include '/gems/' # hides unimportant backtrace
    end

    it "does not spam exception notifier on user erorrs" do
      ErrorNotifier.expects(:notify).never
      job.expects(:running!).raises(Samson::Hooks::UserError, "Oh boy")
      perform
      execution.output.to_s.must_include "JobExecution failed: Oh boy"
    end

    it "does not show error backtraces in production to hide internals" do
      with_hidden_errors do
        ErrorNotifier.expects(:notify)
        job.expects(:running!).raises("Oh boy")
        perform
        execution.output.to_s.must_include "JobExecution failed: Oh boy"
        execution.output.to_s.wont_include model_file
      end
    end

    it "shows exception notifier error location" do
      with_hidden_errors do
        ErrorNotifier.expects(:notify).with { |_e, o| assert o.key?(:sync) }.returns('foo')
        job.expects(:running!).raises("Oh boy")
        perform
        execution.output.to_s.must_include "Error URL: foo"
      end
    end
  end

  describe "#cancel" do
    def perform
      JobQueue.instance.instance_variable_get(:@threads)[execution.id] = Thread.new { execution.perform }
      Thread.pass # make sure thread starts
    end

    with_job_cancel_timeout 0.1

    let(:lock) { Mutex.new }
    let(:execution) { JobExecution.new('master', job) { lock.lock } }

    before do
      execution.executor.expects(:execute).never # avoid executing any commands
      execution.stubs(:setup).returns(true) # avoid state from executing git commands
      lock.lock # pretend things are stalling
    end

    it "stops the execution with interrupt" do
      perform
      TerminalExecutor.any_instance.expects(:cancel).with do |signal|
        lock.unlock # pretend the command finished
        signal.must_equal 'INT'
        true
      end
      execution.cancel
    end

    it "stops the execution with kill if job did not respond to interrupt" do
      perform
      TerminalExecutor.any_instance.expects(:cancel).twice.with do |signal|
        lock.unlock if signal == 'KILL' # pretend the command finished
        ['KILL', 'INT'].must_include(signal)
        true
      end
      execution.cancel
    end

    it "calls on_finish hooks once when killing stuck thread" do
      called = []
      execution.on_finish { called << 1 }
      perform
      execution.cancel
      called.must_equal [1]
    end

    it "calls on_finish hooks once when stopping execution with INT" do
      called = []
      execution.on_finish { called << 1 }
      perform
      TerminalExecutor.any_instance.expects(:cancel).with do |signal|
        lock.unlock # pretend the command finished
        signal.must_equal 'INT'
        true
      end
      execution.cancel
      called.must_equal [1]
    end

    it "stops the build-finder" do
      perform
      Samson::BuildFinder.any_instance.expects(:cancelled!).with do
        lock.unlock
        true
      end
      execution.cancel
    end
  end

  describe "#pid" do
    it "returns current pid" do
      job.command = 'sleep 0.5'
      execution = JobExecution.new('master', job)
      JobQueue.perform_later(execution)
      sleep 0.4
      execution.pid.wont_equal nil
      JobQueue.wait(execution.id)
    end
  end

  describe "#make_tempdir" do
    # the actual issue we saw was Errno::ENOTEMPTY ... but that is harder to reproduce
    it "does not fail when directory cannot be removed" do
      ErrorNotifier.expects(:notify).with { |e| e.must_include "Notify: make_tempdir error No such" }

      execution.send(:make_tempdir) do |dir|
        FileUtils.rm_rf(dir)
        111
      end.must_equal 111
    end
  end
end
