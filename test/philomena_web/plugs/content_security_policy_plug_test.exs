defmodule PhilomenaWeb.ContentSecurityPolicyPlugTest do
  use ExUnit.Case, async: true
  alias PhilomenaWeb.ContentSecurityPolicyPlug

  test "permits Derpibooru thumbnails only on explicitly opted-in responses" do
    conn = Plug.Test.conn(:get, "/") |> ContentSecurityPolicyPlug.call([])
    normal = Plug.Conn.send_resp(conn, 200, "")
    refute hd(Plug.Conn.get_resp_header(normal, "content-security-policy")) =~ "derpicdn.net"

    opted_in =
      conn
      |> ContentSecurityPolicyPlug.permit_source(:img_src, [
        "https://derpicdn.net",
        "https://derpibooru.org"
      ])
      |> Plug.Conn.send_resp(200, "")

    policy = hd(Plug.Conn.get_resp_header(opted_in, "content-security-policy"))
    image_policy = policy |> String.split(";") |> Enum.find(&String.contains?(&1, "img-src"))
    assert image_policy =~ "https://derpicdn.net"
    assert image_policy =~ "https://derpibooru.org"
    assert policy =~ "object-src 'none'"
  end
end
