# Pleroma: A lightweight social networking server
# Copyright © 2017-2020 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.HTTP.AdapterHelper.Gun do
  @behaviour Pleroma.HTTP.AdapterHelper

  require Logger

  alias Pleroma.HTTP.AdapterHelper
  alias Pleroma.Pool.Connections

  @defaults [
    connect_timeout: 5_000,
    domain_lookup_timeout: 5_000,
    tls_handshake_timeout: 5_000,
    retry: 1,
    retry_timeout: 1000,
    await_up_timeout: 5_000
  ]

  @spec options(keyword(), URI.t()) :: keyword()
  def options(connection_opts \\ [], %URI{} = uri) do
    formatted_proxy =
      Pleroma.Config.get([:http, :proxy_url], nil)
      |> AdapterHelper.format_proxy()

    config_opts = Pleroma.Config.get([:http, :adapter], [])

    @defaults
    |> Keyword.merge(config_opts)
    |> add_scheme_opts(uri)
    |> AdapterHelper.maybe_add_proxy(formatted_proxy)
    |> maybe_get_conn(uri, connection_opts)
  end

  @spec after_request(keyword()) :: :ok
  def after_request(opts) do
    if opts[:conn] && opts[:body_as] != :chunks do
      Connections.checkout(opts[:conn], self(), :gun_connections)
    end

    :ok
  end

  defp add_scheme_opts(opts, %URI{scheme: "http"}), do: opts

  defp add_scheme_opts(opts, %URI{scheme: "https", host: host}) do
    adapter_opts = [
      certificates_verification: true,
      transport: :tls,
      tls_opts: [
        verify: :verify_peer,
        cacertfile: CAStore.file_path(),
        depth: 20,
        reuse_sessions: false,
        verify_fun: {&:ssl_verify_hostname.verify_fun/3, [check_hostname: format_host(host)]},
        log_level: :warning
      ]
    ]

    Keyword.merge(opts, adapter_opts)
  end

  defp maybe_get_conn(adapter_opts, uri, connection_opts) do
    {receive_conn?, opts} =
      adapter_opts
      |> Keyword.merge(connection_opts)
      |> Keyword.pop(:receive_conn, true)

    if Connections.alive?(:gun_connections) and receive_conn? do
      try_to_get_conn(uri, opts)
    else
      opts
    end
  end

  defp try_to_get_conn(uri, opts) do
    case Connections.checkin(uri, :gun_connections) do
      nil ->
        Logger.debug(
          "Gun connections pool checkin was not successful. Trying to open conn for next request."
        )

        Task.start(fn -> Pleroma.Gun.Conn.open(uri, :gun_connections, opts) end)
        opts

      conn when is_pid(conn) ->
        Logger.debug("received conn #{inspect(conn)} #{Connections.compose_uri_log(uri)}")

        opts
        |> Keyword.put(:conn, conn)
        |> Keyword.put(:close_conn, false)
    end
  end

  @spec format_host(String.t()) :: charlist()
  def format_host(host) do
    host_charlist = to_charlist(host)

    case :inet.parse_address(host_charlist) do
      {:error, :einval} ->
        :idna.encode(host_charlist)

      {:ok, _ip} ->
        host_charlist
    end
  end
end
