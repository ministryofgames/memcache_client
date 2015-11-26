defmodule Memcache.Client do

  @moduledoc"""
  Binary protocol client for Memcached server.
  """
  
  use Application

  alias Memcache.Client.Serialization.Header
  alias Memcache.Client.Serialization.Opcode

  @type key :: binary
  @type value :: any
  @type opts :: Keyword.t
  
  defmodule Response do
    defstruct key: "", value: "", extras: "", status: nil, cas: 0, data_type: nil
    @type t :: %Response{key: binary, value: any, extras: binary, status: atom,
                         cas: non_neg_integer, data_type: non_neg_integer}
  end
  
  defmodule Request do
    defstruct opcode: nil, key: "", value: "", extras: "", cas: 0
    @type t :: %Request{opcode: atom, key: binary, value: any,
                        extras: binary, cas: non_neg_integer}
  end
  
  def start(_type, _args) do
    import Supervisor.Spec, warn: false
    
    pool_args = [name: {:local, Memcache.Client.Pool},
                 worker_module: Memcache.Client.Worker,
                 size: Application.get_env(:memcache_client, :pool_size, 5),
                 max_overflow: Application.get_env(:memcache_client,
                                                   :pool_max_overflow, 10)]
    worker_args = [host: Application.get_env(:memcache_client, :host, "127.0.0.1"),
                   port: Application.get_env(:memcache_client, :port, 11211),
                   auth_method: Application.get_env(:memcache_client, :auth_method, :none),
                   username: Application.get_env(:memcache_client, :username, ""),
                   password: Application.get_env(:memcache_client, :password, "")]
    
    poolboy_sup = :poolboy.child_spec(Memcache.Client.Pool.Supervisor,
                                      pool_args, worker_args)
    
    children = [
      poolboy_sup
    ]
    
    opts = [strategy: :one_for_one, name: Memcache.Client.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Gets `value` for given `key`.
  """
  @spec get(key) :: Response.t
  def get(key) do
    request = %Request{opcode: :get, key: key}
    [response] = multi_request([request], false)
    
    response
  end

  @doc """
  Gets values for multiple `keys` with a single pipelined operation.
  """
  @spec mget(Enumerable.t) :: Stream.t
  def mget(keys) do
    requests = Enum.map(keys, &(%Request{opcode: :get, key: &1}))
    multi_request(requests)
  end

  @doc """
  Sets `value` for given `key`.
  """
  @spec set(key, value, opts) :: Response.t
  def set(key, value, opts \\ []), do: do_store(:set, key, value, opts)

  @doc """
  Sets multiple `values` with a single pipelined operation. Value
  needs to be a tuple of `key` and `value`.
  """
  @spec mset(Enumerable.t) :: Stream.t
  def mset(keyvalues) do
    requests = keyvalues
    |> Enum.map(
      fn {key, value} ->
        store_request(:set, key, value, [])
      end)
    multi_request(requests)
  end
  
  @doc """
  Sets `value` for given `key` only if it does not already exist.
  """
  @spec add(key, value, opts) :: Response.t
  def add(key, value, opts \\ []), do: do_store(:add, key, value, opts)

  @doc """
  Sets `value`for given `key` only if it already exists.
  """
  @spec replace(key, value, opts) :: Response.t
  def replace(key, value, opts \\ []), do: do_store(:replace, key, value, opts)

  @doc """
  Appends `value` to given `key` if it already exists.
  """
  @spec append(key, value) :: Response.t
  def append(key, value) do
    request = %Request{opcode: :append, key: key, value: value}
    [response] = multi_request([request], false)
    
    response
  end

  @doc """
  Prepends `value` to given `key` if it already exists.
  """
  @spec prepend(key, value) :: Response.t
  def prepend(key, value) do
    request = %Request{opcode: :prepend, key: key, value: value}
    [response] = multi_request([request], false)

    response
  end
  
  @doc """
  Deletes the `value` for the given `key`.
  """
  @spec delete(key) :: Response.t
  def delete(key) do
    request = %Request{opcode: :delete, key: key}
    [response] = multi_request([request], false)

    response
  end

  @doc """
  Increments a counter on given `key`.
  """
  @spec increment(key, pos_integer, opts) :: Response.t
  def increment(key, amount, opts \\ []), do: do_incr_decr(:increment, key, amount, opts)

  @doc """
  Decrements a counter on given `key`.
  """
  @spec decrement(key, pos_integer, opts) :: Response.t
  def decrement(key, amount, opts \\ []), do: do_incr_decr(:decrement, key, amount, opts)

  @doc """
  Flushes the cache.
  """
  @spec flush(opts) :: Response.t
  def flush(opts \\ []) do
    expires = Keyword.get(opts, :expires, 0)

    extras = <<expires :: size(32)>>

    request = %Request{opcode: :flush, extras: extras}
    [response] = multi_request([request], false)
    
    response
  end

  @doc """
  Returns the current memcached version.
  """
  @spec version() :: Response.t
  def version() do
    request = %Request{opcode: :version}
    [response] = multi_request([request], false)
    
    response
  end

  ## private api
  
  defp multi_request(requests, return_stream \\ true) do
    stream = Stream.resource(
      fn ->
        worker = :poolboy.checkout(Memcache.Client.Pool)
        :ok = do_multi_request(requests, worker)
        {worker, :cont}
      end,
      fn
        {worker, :cont} = acc ->
          # stream responses
          receive do
            {:response, {:ok, header, key, value, extras}} ->
              response = %Response{status: header.status, cas: header.cas,
                                   key: key, value: value, extras: extras}

              # apply transcoder for get operations
              if extras != "" and Opcode.get?(header.opcode) do
                <<type_flag :: size(32)>> = extras
                case Memcache.Client.Transcoder.decode_value(response.value, type_flag) do
                  {:error, _error} ->
                    response = %{response | status: :transcode_error,
                                 value: "Transcode error"}
                  {:ok, value} ->
                    response = %{response | value: value, data_type: type_flag}
                end
              end
              
              if not Opcode.quiet?(header.opcode) do
                # we'll halt since there won't be anymore results
                {[response], {worker, :halt}}
              else
                {[response], acc}
              end
          end
        {_worker, :halt} = acc ->
          {:halt, acc}
      end,
      fn {worker, _} ->
        :poolboy.checkin(Memcache.Client.Pool, worker)
      end)
    
    if return_stream do
      stream
    else
      stream |> Enum.into([])
    end
  end
  
  defp do_multi_request([request], worker) do
    GenServer.cast(worker, {:request, self,
                            %Header{opcode: request.opcode, cas: request.cas},
                            request.key, request.value, request.extras})
  end
  
  defp do_multi_request([request | requests], worker) do
    GenServer.cast(worker,
                   {:request,
                    self,
                    %Header{opcode: Opcode.to_quiet(request.opcode), cas: request.cas},
                    request.key, request.value, request.extras})
    do_multi_request(requests, worker)
  end

  defp do_store(opcode, key, value, opts) do
    request = store_request(opcode, key, value, opts)
    [response] = multi_request([request], false)
        
    response
  end

  defp store_request(opcode, key, value, opts) do
    expires = Keyword.get(opts, :expires, 0)
    cas     = Keyword.get(opts, :cas, 0)

    {:ok, value, flags} = Memcache.Client.Transcoder.encode_value(value)
    extras = <<flags :: size(32), expires :: size(32)>>

    %Request{opcode: opcode, key: key, value: value, extras: extras, cas: cas}
  end

  defp do_incr_decr(opcode, key, amount, opts) do
    initial_value = Keyword.get(opts, :initial_value, 0)
    expires       = Keyword.get(opts, :expires, 0)
    
    extras = <<amount :: size(64), initial_value :: size(64), expires :: size(32)>>

    request = %Request{opcode: opcode, key: key, extras: extras}
    [response] = multi_request([request], false)
    
    if response.status == :ok do
      <<value :: unsigned-integer-size(64)>> = response.value
      %{response | value: value}
    else
      response
    end
  end

end
