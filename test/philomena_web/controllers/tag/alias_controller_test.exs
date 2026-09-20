defmodule PhilomenaWeb.Tag.AliasControllerTest do
  use PhilomenaWeb.ConnCase, async: false

  import Philomena.UsersFixtures
  alias Philomena.Repo
  alias Philomena.Tags
  alias Philomena.Tags.Tag
  alias Philomena.Users.User
  alias Philomena.ModerationLogs.ModerationLog

  setup %{conn: conn} do
    admin = confirmed_user_fixture() |> Ecto.Changeset.change(role: "admin") |> Repo.update!()
    {:ok, tag} = Tags.create_tag(%{name: "source"})
    %{conn: log_in_user(conn, admin), tag: tag}
  end

  test "XHR creates the target, aliases the source and logs the action", %{conn: conn, tag: tag} do
    conn = conn |> xhr() |> put(~p"/tags/#{tag}/alias", %{tag: %{target_tag: "New Target"}})
    assert json_response(conn, 200) == %{"success" => true}
    target = Tags.get_tag_by_name("new target")
    assert Repo.get!(Tag, tag.id).aliased_tag_id == target.id
    assert Repo.one!(ModerationLog).body == "Aliased tag 'source' into 'new target'"
  end

  test "XHR returns the actual validation reason", %{conn: conn, tag: tag} do
    conn = conn |> xhr() |> put(~p"/tags/#{tag}/alias", %{tag: %{target_tag: "source"}})
    assert %{"success" => false, "error" => reason} = json_response(conn, 422)
    assert reason =~ "is the same tag as the source"
    assert Repo.aggregate(ModerationLog, :count) == 0
  end

  test "missing parameters return validation errors", %{conn: conn, tag: tag} do
    conn = conn |> xhr() |> put(~p"/tags/#{tag}/alias", %{})
    assert json_response(conn, 422)["error"] =~ "one non-empty target tag name"
  end

  test "ordinary users cannot create aliases or target tags", %{conn: conn, tag: tag} do
    user = confirmed_user_fixture()

    conn =
      conn
      |> log_in_user(user)
      |> xhr()
      |> put(~p"/tags/#{tag}/alias", %{tag: %{target_tag: "forbidden"}})

    assert response(conn, 403)
    assert Tags.get_tag_by_name("forbidden") == nil
    assert Repo.get!(Tag, tag.id).aliased_tag_id == nil
  end

  test "a tag administrator can alias", %{conn: conn, tag: tag} do
    user =
      confirmed_user_fixture()
      |> Repo.preload(:roles)
      |> Ecto.Changeset.change(role: "moderator")
      |> Ecto.Changeset.put_assoc(:roles, [
        %Philomena.Roles.Role{name: "admin", resource_type: "Tag"}
      ])
      |> Repo.update!()

    conn =
      conn
      |> log_in_user(user)
      |> xhr()
      |> put(~p"/tags/#{tag}/alias", %{tag: %{target_tag: "allowed"}})

    assert json_response(conn, 200)["success"]
  end

  test "normal HTML form submissions retain their redirect", %{conn: conn, tag: tag} do
    conn = put(conn, ~p"/tags/#{tag}/alias", %{tag: %{target_tag: "target"}})
    assert redirected_to(conn) == ~p"/tags/#{tag}/alias/edit"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Tag alias queued."
  end

  test "normal HTML validation failures retain the form and errors", %{conn: conn, tag: tag} do
    conn = put(conn, ~p"/tags/#{tag}/alias", %{tag: %{target_tag: "source"}})
    assert html_response(conn, 200) =~ "is the same tag as the source"
  end

  test "the dropdown renders Alias only with alias permission", %{conn: conn, tag: tag} do
    for {user, allowed} <- [
          {nil, false},
          {%User{role: "user"}, false},
          {%User{role: "moderator"}, false},
          {%User{role: "admin"}, true},
          {%User{role: "moderator", role_map: %{"Tag" => %{"admin" => true}}}, true}
        ] do
      html =
        Phoenix.View.render_to_string(PhilomenaWeb.TagView, "_tag.html",
          tag: tag,
          conn: assign(conn, :current_user, user)
        )

      assert String.contains?(html, "data-tag-alias-url") == allowed
      if allowed, do: assert(html =~ ~s(data-tag-alias-url="/tags/source/alias"))
    end
  end

  defp xhr(conn), do: put_req_header(conn, "x-requested-with", "XMLHttpRequest")
end
