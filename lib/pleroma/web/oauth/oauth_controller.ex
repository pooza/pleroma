# Pleroma: A lightweight social networking server
# Copyright © 2017-2019 Pleroma Authors <https://pleroma.social/>
# SPDX-License-Identifier: AGPL-3.0-only

defmodule Pleroma.Web.OAuth.OAuthController do
  use Pleroma.Web, :controller

  alias Pleroma.Registration
  alias Pleroma.Repo
  alias Pleroma.User
  alias Pleroma.Web.Auth.Authenticator
  alias Pleroma.Web.ControllerHelper
  alias Pleroma.Web.OAuth.App
  alias Pleroma.Web.OAuth.Authorization
  alias Pleroma.Web.OAuth.Token
  alias Pleroma.Web.OAuth.Token.Strategy.RefreshToken
  alias Pleroma.Web.OAuth.Token.Strategy.Revoke, as: RevokeToken
  alias Pleroma.Web.OAuth.Scopes

  if Pleroma.Config.oauth_consumer_enabled?(), do: plug(Ueberauth)

  plug(:fetch_session)
  plug(:fetch_flash)

  action_fallback(Pleroma.Web.OAuth.FallbackController)

  # Note: this definition is only called from error-handling methods with `conn.params` as 2nd arg
  def authorize(conn, %{"authorization" => _} = params) do
    {auth_attrs, params} = Map.pop(params, "authorization")
    authorize(conn, Map.merge(params, auth_attrs))
  end

  def authorize(%{assigns: %{token: %Token{} = token}} = conn, params) do
    if ControllerHelper.truthy_param?(params["force_login"]) do
      do_authorize(conn, params)
    else
      redirect_uri =
        if is_binary(params["redirect_uri"]) do
          params["redirect_uri"]
        else
          app = Repo.preload(token, :app).app

          app.redirect_uris
          |> String.split()
          |> Enum.at(0)
        end

      redirect(conn, external: redirect_uri(conn, redirect_uri))
    end
  end

  def authorize(conn, params), do: do_authorize(conn, params)

  defp do_authorize(conn, %{"client_id" => "pleroma:blocked"}) do
    render(conn, "blocked.html")
  end

  defp do_authorize(conn, params) do
    app = Repo.get_by(App, client_id: params["client_id"])
    available_scopes = (app && app.scopes) || []
    scopes = Scopes.fetch_scopes(params, available_scopes)

    # Note: `params` might differ from `conn.params`; use `@params` not `@conn.params` in template
    render(conn, Authenticator.auth_template(), %{
      response_type: params["response_type"],
      client_id: params["client_id"],
      available_scopes: available_scopes,
      scopes: scopes,
      redirect_uri: params["redirect_uri"],
      state: params["state"],
      params: params
    })
  end

  def create_authorization(
        conn,
        %{"authorization" => _} = params,
        opts \\ []
      ) do
    with {:ok, auth} <- do_create_authorization(conn, params, opts[:user]) do
      after_create_authorization(conn, auth, params)
    else
      error ->
        handle_create_authorization_error(conn, error, params)
    end
  end

  def after_create_authorization(conn, auth, %{
        "authorization" => %{"redirect_uri" => redirect_uri} = auth_attrs
      }) do
    redirect_uri = redirect_uri(conn, redirect_uri)

    if redirect_uri == "urn:ietf:wg:oauth:2.0:oob" do
      render(conn, "results.html", %{
        auth: auth
      })
    else
      connector = if String.contains?(redirect_uri, "?"), do: "&", else: "?"
      url = "#{redirect_uri}#{connector}"
      url_params = %{:code => auth.token}

      url_params =
        if auth_attrs["state"] do
          Map.put(url_params, :state, auth_attrs["state"])
        else
          url_params
        end

      url = "#{url}#{Plug.Conn.Query.encode(url_params)}"

      redirect(conn, external: url)
    end
  end

  defp handle_create_authorization_error(
         conn,
         {:error, scopes_issue},
         %{"authorization" => _} = params
       )
       when scopes_issue in [:unsupported_scopes, :missing_scopes] do
    # Per https://github.com/tootsuite/mastodon/blob/
    #   51e154f5e87968d6bb115e053689767ab33e80cd/app/controllers/api/base_controller.rb#L39
    conn
    |> put_flash(:error, "This action is outside the authorized scopes")
    |> put_status(:unauthorized)
    |> authorize(params)
  end

  defp handle_create_authorization_error(
         conn,
         {:auth_active, false},
         %{"authorization" => _} = params
       ) do
    # Per https://github.com/tootsuite/mastodon/blob/
    #   51e154f5e87968d6bb115e053689767ab33e80cd/app/controllers/api/base_controller.rb#L76
    conn
    |> put_flash(:error, "Your login is missing a confirmed e-mail address")
    |> put_status(:forbidden)
    |> authorize(params)
  end

  defp handle_create_authorization_error(conn, error, %{"authorization" => _}) do
    Authenticator.handle_error(conn, error)
  end

  @doc "Renew access_token with refresh_token"
  def token_exchange(
        conn,
        %{"grant_type" => "refresh_token", "refresh_token" => token} = _params
      ) do
    with {:ok, app} <- Token.Utils.fetch_app(conn),
         {:ok, %{user: user} = token} <- Token.get_by_refresh_token(app, token),
         {:ok, token} <- RefreshToken.grant(token) do
      response_attrs = %{created_at: Token.Utils.format_created_at(token)}

      json(conn, Token.Response.build(user, token, response_attrs))
    else
      _error ->
        put_status(conn, 400)
        |> json(%{error: "Invalid credentials"})
    end
  end

  def token_exchange(conn, %{"grant_type" => "authorization_code"} = params) do
    with {:ok, app} <- Token.Utils.fetch_app(conn),
         fixed_token = Token.Utils.fix_padding(params["code"]),
         {:ok, auth} <- Authorization.get_by_token(app, fixed_token),
         %User{} = user <- User.get_cached_by_id(auth.user_id),
         {:ok, token} <- Token.exchange_token(app, auth) do
      response_attrs = %{created_at: Token.Utils.format_created_at(token)}

      json(conn, Token.Response.build(user, token, response_attrs))
    else
      _error ->
        put_status(conn, 400)
        |> json(%{error: "Invalid credentials"})
    end
  end

  def token_exchange(
        conn,
        %{"grant_type" => "password"} = params
      ) do
    with {:ok, %User{} = user} <- Authenticator.get_user(conn),
         {:ok, app} <- Token.Utils.fetch_app(conn),
         {:auth_active, true} <- {:auth_active, User.auth_active?(user)},
         {:user_active, true} <- {:user_active, !user.info.deactivated},
         {:ok, scopes} <- validate_scopes(app, params),
         {:ok, auth} <- Authorization.create_authorization(app, user, scopes),
         {:ok, token} <- Token.exchange_token(app, auth) do
      json(conn, Token.Response.build(user, token))
    else
      {:auth_active, false} ->
        # Per https://github.com/tootsuite/mastodon/blob/
        #   51e154f5e87968d6bb115e053689767ab33e80cd/app/controllers/api/base_controller.rb#L76
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Your login is missing a confirmed e-mail address"})

      {:user_active, false} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Your account is currently disabled"})

      _error ->
        put_status(conn, 400)
        |> json(%{error: "Invalid credentials"})
    end
  end

  def token_exchange(
        conn,
        %{"grant_type" => "password", "name" => name, "password" => _password} = params
      ) do
    params =
      params
      |> Map.delete("name")
      |> Map.put("username", name)

    token_exchange(conn, params)
  end

  def token_exchange(conn, %{"grant_type" => "client_credentials"} = _params) do
    with {:ok, app} <- Token.Utils.fetch_app(conn),
         {:ok, auth} <- Authorization.create_authorization(app, %User{}),
         {:ok, token} <- Token.exchange_token(app, auth) do
      json(conn, Token.Response.build_for_client_credentials(token))
    else
      _error ->
        put_status(conn, 400)
        |> json(%{error: "Invalid credentials"})
    end
  end

  # Bad request
  def token_exchange(conn, params), do: bad_request(conn, params)

  def token_revoke(conn, %{"token" => _token} = params) do
    with {:ok, app} <- Token.Utils.fetch_app(conn),
         {:ok, _token} <- RevokeToken.revoke(app, params) do
      json(conn, %{})
    else
      _error ->
        # RFC 7009: invalid tokens [in the request] do not cause an error response
        json(conn, %{})
    end
  end

  def token_revoke(conn, params), do: bad_request(conn, params)

  # Response for bad request
  defp bad_request(conn, _) do
    conn
    |> put_status(500)
    |> json(%{error: "Bad request"})
  end

  @doc "Prepares OAuth request to provider for Ueberauth"
  def prepare_request(conn, %{"provider" => provider, "authorization" => auth_attrs}) do
    scope =
      auth_attrs
      |> Scopes.fetch_scopes([])
      |> Scopes.to_string()

    state =
      auth_attrs
      |> Map.delete("scopes")
      |> Map.put("scope", scope)
      |> Jason.encode!()

    params =
      auth_attrs
      |> Map.drop(~w(scope scopes client_id redirect_uri))
      |> Map.put("state", state)

    # Handing the request to Ueberauth
    redirect(conn, to: o_auth_path(conn, :request, provider, params))
  end

  def request(conn, params) do
    message =
      if params["provider"] do
        "Unsupported OAuth provider: #{params["provider"]}."
      else
        "Bad OAuth request."
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: "/")
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, params) do
    params = callback_params(params)
    messages = for e <- Map.get(failure, :errors, []), do: e.message
    message = Enum.join(messages, "; ")

    conn
    |> put_flash(:error, "Failed to authenticate: #{message}.")
    |> redirect(external: redirect_uri(conn, params["redirect_uri"]))
  end

  def callback(conn, params) do
    params = callback_params(params)

    with {:ok, registration} <- Authenticator.get_registration(conn) do
      auth_attrs = Map.take(params, ~w(client_id redirect_uri scope scopes state))

      case Repo.get_assoc(registration, :user) do
        {:ok, user} ->
          create_authorization(conn, %{"authorization" => auth_attrs}, user: user)

        _ ->
          registration_params =
            Map.merge(auth_attrs, %{
              "nickname" => Registration.nickname(registration),
              "email" => Registration.email(registration)
            })

          conn
          |> put_session(:registration_id, registration.id)
          |> registration_details(%{"authorization" => registration_params})
      end
    else
      _ ->
        conn
        |> put_flash(:error, "Failed to set up user account.")
        |> redirect(external: redirect_uri(conn, params["redirect_uri"]))
    end
  end

  defp callback_params(%{"state" => state} = params) do
    Map.merge(params, Jason.decode!(state))
  end

  def registration_details(conn, %{"authorization" => auth_attrs}) do
    render(conn, "register.html", %{
      client_id: auth_attrs["client_id"],
      redirect_uri: auth_attrs["redirect_uri"],
      state: auth_attrs["state"],
      scopes: Scopes.fetch_scopes(auth_attrs, []),
      nickname: auth_attrs["nickname"],
      email: auth_attrs["email"]
    })
  end

  def register(conn, %{"authorization" => _, "op" => "connect"} = params) do
    with registration_id when not is_nil(registration_id) <- get_session_registration_id(conn),
         %Registration{} = registration <- Repo.get(Registration, registration_id),
         {_, {:ok, auth}} <-
           {:create_authorization, do_create_authorization(conn, params)},
         %User{} = user <- Repo.preload(auth, :user).user,
         {:ok, _updated_registration} <- Registration.bind_to_user(registration, user) do
      conn
      |> put_session_registration_id(nil)
      |> after_create_authorization(auth, params)
    else
      {:create_authorization, error} ->
        {:register, handle_create_authorization_error(conn, error, params)}

      _ ->
        {:register, :generic_error}
    end
  end

  def register(conn, %{"authorization" => _, "op" => "register"} = params) do
    with registration_id when not is_nil(registration_id) <- get_session_registration_id(conn),
         %Registration{} = registration <- Repo.get(Registration, registration_id),
         {:ok, user} <- Authenticator.create_from_registration(conn, registration) do
      conn
      |> put_session_registration_id(nil)
      |> create_authorization(
        params,
        user: user
      )
    else
      {:error, changeset} ->
        message =
          Enum.map(changeset.errors, fn {field, {error, _}} ->
            "#{field} #{error}"
          end)
          |> Enum.join("; ")

        message =
          String.replace(
            message,
            "ap_id has already been taken",
            "nickname has already been taken"
          )

        conn
        |> put_status(:forbidden)
        |> put_flash(:error, "Error: #{message}.")
        |> registration_details(params)

      _ ->
        {:register, :generic_error}
    end
  end

  defp do_create_authorization(
         conn,
         %{
           "authorization" =>
             %{
               "client_id" => client_id,
               "redirect_uri" => redirect_uri
             } = auth_attrs
         },
         user \\ nil
       ) do
    with {_, {:ok, %User{} = user}} <-
           {:get_user, (user && {:ok, user}) || Authenticator.get_user(conn)},
         %App{} = app <- Repo.get_by(App, client_id: client_id),
         true <- redirect_uri in String.split(app.redirect_uris),
         {:ok, scopes} <- validate_scopes(app, auth_attrs),
         {:auth_active, true} <- {:auth_active, User.auth_active?(user)} do
      Authorization.create_authorization(app, user, scopes)
    end
  end

  # Special case: Local MastodonFE
  defp redirect_uri(conn, "."), do: mastodon_api_url(conn, :login)

  defp redirect_uri(_conn, redirect_uri), do: redirect_uri

  defp get_session_registration_id(conn), do: get_session(conn, :registration_id)

  defp put_session_registration_id(conn, registration_id),
    do: put_session(conn, :registration_id, registration_id)

  @spec validate_scopes(App.t(), map()) ::
          {:ok, list()} | {:error, :missing_scopes | :unsupported_scopes}
  defp validate_scopes(app, params) do
    params
    |> Scopes.fetch_scopes(app.scopes)
    |> Scopes.validates(app.scopes)
  end
end
