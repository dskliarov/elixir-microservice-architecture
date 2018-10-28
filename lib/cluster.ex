require Logger

defmodule App do
  @moduledoc """
  """
  use Application

  def start(_type, _args) do
    App.start()
  end

  def start() do
    Cluster.summary()
    Application.ensure_all_started(:sidetask)
    SideTask.add_resource(:registration_loop, 1)
    SideTask.add_resource(:join_loop, 1)
    SideTask.add_resource(:worker_loop, 1)

    {:ok, _pid} = Cluster.start_link()
    SideTask.start_child(:worker_loop, &Cluster.Node.worker_loop/0)
    SideTask.start_child(:registration_loop, &Cluster.Node.registration_loop/0)
    SideTask.start_child(:join_loop, &Cluster.Node.connection_loop/0)
  end
end

defmodule Cluster.Node do

  @heartbeat_delta 3000 # String.to_integer(@redis_ttl*1000) - 2000
  @worker_delta 3000
  @max_workers 100
  @doc """
  Establish connections between myself and known Elixir VMs
  """
  def connection_loop() do
    members = Enum.filter(Cluster.members(), fn x -> x != Node.self() end)
    #Logger.info("Connecting to #{members}")
    Enum.each(members, fn m -> Node.connect(m) end)
    :timer.sleep(@heartbeat_delta)
    connection_loop()
  end

  @doc """
  Heartbeat.  We write into the registration repeatedly to
  indicate Cluster.Node is live, because entries in registration all
  get TTLs
  """
  def registration_loop() do
    Cluster.join()
    :timer.sleep(@heartbeat_delta)
    registration_loop()
  end

  @doc """
  """
  def worker_loop() do
    pid = Cluster.pid()
    {:ok, [_next_cursor, keys]} = Redix.command(pid, [ "SCAN", "0", "MATCH", "[_]*", "COUNT", @max_workers+1])
    Apex.ap keys
    keys = Enum.drop_while(keys, fn k->
        {:ok, status} = Redix.command(pid, ["GET", k])
        Logger.info("#{k} status #{status}")
        not String.equivalent?(status, "pending")
      end)
    if Enum.empty?(keys) do
      Logger.info("worker-loop finds no work")
    else
      key = Enum.at(keys, 0)
      Callback.write(key, "working")
      Apex.ap Redix.command(pid, ["GET", key])
      :timer.sleep(3000)
      Callback.write(key, "worked")
    end
    :timer.sleep(@worker_delta)
    worker_loop()
  end
end

defmodule Cluster do
  @moduledoc """
  """

  @redis_ttl System.get_env("REDIS_TTL") || "6"
  @redis_host System.get_env("REDIS_HOST") || "redis"
  @redis_port String.to_integer(System.get_env("REDIS_PORT") || "6379")
  @max_members 999

  def pid(), do: Process.whereis(__MODULE__)

  def summary do
    Apex.ap "Node: " <> Functions.red(Atom.to_string(Node.self()))
    Apex.ap "Schedulers: #{:erlang.system_info(:schedulers)}"
    Apex.ap "Redis host: " <> Functions.red(@redis_host)
    Apex.ap "Redis port: " <> Functions.red(@redis_port)
  end

  def start_link do
    {:ok, _conn} = Redix.start_link(
      "redis://#{@redis_host}:#{@redis_port}/", name: __MODULE__,)
  end

  @doc """
  """
  def join() do
   pid = Cluster.pid()
   Logger.info "Sending Heartbeat for #{Node.self|>Atom.to_string}"
   this_name = Node.self() |> Atom.to_string
   Redix.command(pid,
         [ "SETEX", this_name,
           @redis_ttl,
           this_name, ])
  end

  @doc """
  Should not be used in production.. see https://redis.io/commands/keys
  """
  def keys() do
    pid = Cluster.pid()
    case Redix.command(pid, ["KEYS", "*"]) do
     {:error, _ } ->
       []
     {:ok, keys} ->
       Enum.map(keys, &String.to_atom/1)
    end
  end

  @doc """
  """
  def members() do
    index = 0
    count = @max_members
    pid = Cluster.pid()
    case Redix.command(pid, ["SCAN", index, "MATCH", "[^_]*", "COUNT", count]) do
      {:error, _ } ->
        [] #members(cluster)
      {:ok, [_given_index, member_data]} ->
        Enum.map(member_data, &String.to_atom/1)
    end
  end
end
