# frozen_string_literal: true

require 'json'
require 'tty-prompt'
require 'tty-option'

class Command
  include TTY::Option

  usage do
    program 'ecs-console'
    no_command
    header 'ECS Console'
    desc 'Run commands with environment variables from ECS task definitions'
    example 'ecs-console --cluster production --service my-service --command "rails c"'
    footer 'Run --help (-h) to see more info'
  end

  option :cluster do
    short '-c CLUSTER'
    long '--cluster CLUSTER'
    default 'production'
    permit %w[production staging workers-production workers-staging]
    desc 'Cluster name'
  end

  option :service do
    short '-s SERVICE'
    long '--service SERVICE'
    desc 'Service name. If not provided, will be prompted to select one'
  end

  option :command do
    long '--command COMMAND'
    default 'rails console'
    desc 'Command to run'
  end

  flag :help do
    short '-h'
    long  '--help'
    desc 'Print usage'
  end

  def run
    if params[:help]
      print help
    elsif params.errors.any?
      puts params.errors.summary
    end
  end
end

class Program
  def initialize
    @cmd = Command.new
    @all_env = {}
  end

  def run
    parse_args
    service = cmd.params[:service] || query_services
    _environment, secrets = fetch_environment_and_secrets(service)
    fetch_secret_values(secrets)
    print_env

    env_hash = all_env.transform_values { _1[:value] }
    pid = Process.spawn(env_hash, cmd.params[:command])
    Process.wait pid

    puts 'DONE'
  rescue Interrupt
    puts 'Aborted'
  end

  private

  def parse_args
    cmd.parse
    cmd.run
    exit 1 if cmd.params[:help] || cmd.params.errors.any?
  end

  def query_services
    services = `aws ecs list-services --cluster #{cmd.params[:cluster]} --query 'serviceArns'`.then do
      next [] if _1 == ''

      JSON.parse(_1)
    end

    return TTY::Prompt.new.select('Select service', services, filter: true) unless services.empty?

    puts "No services found in cluster #{cmd.params[:cluster]}"
    exit 1
  end

  def fetch_environment_and_secrets(service)
    task_definition_arn = `aws ecs describe-services --service #{service} --cluster #{cmd.params[:cluster]}`.then do
      JSON.parse(_1).dig('services', 0, 'taskDefinition')
    end

    if task_definition_arn.nil?
      puts "Service #{service} not found"
      exit 1
    end

    task_definition = `aws ecs describe-task-definition --task-definition #{task_definition_arn}`.then do
      JSON.parse(_1).dig('taskDefinition', 'containerDefinitions', 0)
    end

    task_definition['environment'].each do |env|
      key = env['name']
      value = env['value']
      all_env[key] = { value:, secret: false }
    end

    [task_definition['environment'], task_definition['secrets']]
  end

  def fetch_secret_values(secrets)
    secret_keys = secrets.map { |secret| secret['valueFrom'] }.join(' ')

    `aws ssm get-parameters --with-decryption --names #{secret_keys} --query 'Parameters'`.then do
      JSON.parse(_1).each do |parameter|
        name = parameter['Name']
        value = parameter['Value']
        key = secrets.find { |secret| secret['valueFrom'] == name }['name']
        next if key.nil?

        all_env[key] = { value:, secret: true }
      end
    end
  end

  def print_env
    all_env.each do |key, value|
      if value[:secret]
        puts "#{key}=#{value[:value].gsub(/./, '*')}"
      else
        puts "#{key}=#{value[:value]}"
      end
    end
  end

  attr_reader :cmd, :all_env
end

Program.new.run
