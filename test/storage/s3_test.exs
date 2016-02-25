defmodule ArcTest.Storage.S3 do
  use ExUnit.Case, async: false
  @img "test/support/image.png"

  defmodule DummyDefinition do
    use Arc.Definition

    @acl :public_read
    def storage_dir(_, _), do: "arctest/uploads"
    def acl(_, {_, :private}), do: :private

    def s3_object_headers(:original, {_, :with_content_type}), do: [content_type: "image/gif"]
    def s3_object_headers(:original, {_, :with_content_disposition}), do: %{content_disposition: "attachment; filename=abc.png"}
  end

  defmodule DefinitionWithScope do
    use Arc.Definition
    @acl :public_read
    def storage_dir(_, {_, scope}), do: "uploads/with_scopes/#{scope.id}"
  end

  def env_bucket do
    System.get_env("ARC_TEST_BUCKET")
  end

  defmacro delete_and_assert_not_found(definition, args) do
    quote bind_quoted: [definition: definition, args: args] do
      :ok = definition.delete(args)
      signed_url = DummyDefinition.url(args, signed: true)
      {:ok, {{_, code, msg}, _, _}} = :httpc.request(to_char_list(signed_url))
      assert 404 == code
      assert 'Not Found' == msg
    end
  end

  defmacro assert_header(definition, args, header, value) do
    quote bind_quoted: [definition: definition, args: args, header: header, value: value] do
      url = definition.url(args)
      {:ok, {{_, 200, 'OK'}, headers, _}} = :httpc.request(to_char_list(url))

      char_header = to_char_list(header)

      assert to_char_list(value) == Enum.find_value(headers, fn(
        {^char_header, value}) -> value
        _ -> nil
      end)
    end
  end

  defmacro assert_private(definition, args) do
    quote bind_quoted: [definition: definition, args: args] do
      unsigned_url = definition.url(args)
      {:ok, {{_, code, msg}, _, _}} = :httpc.request(to_char_list(unsigned_url))
      assert code == 403
      assert msg == 'Forbidden'

      signed_url = definition.url(args, signed: true)
      {:ok, {{_, code, msg}, headers, _}} = :httpc.request(to_char_list(signed_url))
      assert code == 200
      assert msg == 'OK'
    end
  end

  defmacro assert_public(definition, args) do
    quote bind_quoted: [definition: definition, args: args] do
      url = definition.url(args)
      {:ok, {{_, code, msg}, headers, _}} = :httpc.request(to_char_list(url))
      assert code == 200
      assert msg == 'OK'
    end
  end

  setup_all do
    Application.ensure_all_started(:httpoison)
    Application.ensure_all_started(:ex_aws)
    Application.put_env :arc, :virtual_host, false
    Application.put_env :arc, :bucket, env_bucket
    # Application.put_env :ex_aws, :s3, [scheme: "https://", host: "s3.amazonaws.com", region: "us-west-2"]
    Application.put_env :ex_aws, :access_key_id, System.get_env("ARC_TEST_S3_KEY")
    Application.put_env :ex_aws, :secret_access_key,  System.get_env("ARC_TEST_S3_SECRET")
  end

  test "virtual_host" do
    Application.put_env :arc, :virtual_host, true
    assert "https://#{env_bucket}.s3.amazonaws.com/arctest/uploads/image.png" == DummyDefinition.url(@img)

    Application.put_env :arc, :virtual_host, false
    assert "https://s3.amazonaws.com/#{env_bucket}/arctest/uploads/image.png" == DummyDefinition.url(@img)
  end

  @tag :s3
  @tag timeout: 15000
  test "public put and get" do
    assert {:ok, "image.png"} == DummyDefinition.store(@img)
    assert_public(DummyDefinition, "image.png")
    delete_and_assert_not_found(DummyDefinition, "image.png")
  end

  @tag :s3
  @tag timeout: 15000
  test "private put and signed get" do
    #put the image as private
    assert {:ok, "image.png"} == DummyDefinition.store({@img, :private})
    assert_private(DummyDefinition, "image.png")
    delete_and_assert_not_found(DummyDefinition, "image.png")
  end

  @tag :s3
  @tag timeout: 15000
  test "content_type" do
    {:ok, "image.png"} = DummyDefinition.store({@img, :with_content_type})
    assert_header(DummyDefinition, "image.png", "content-type", "image/gif")
    delete_and_assert_not_found(DummyDefinition, "image.png")
  end

  @tag :s3
  @tag timeout: 15000
  test "content_disposition" do
    {:ok, "image.png"} = DummyDefinition.store({@img, :with_content_disposition})
    assert_header(DummyDefinition, "image.png", "content-disposition", "attachment; filename=abc.png")
    delete_and_assert_not_found(DummyDefinition, "image.png")
  end

  @tag :s3
  @tag timeout: 150000
  test "delete with scope" do
    scope = %{id: 1}
    {:ok, path} = DefinitionWithScope.store({"test/support/image.png", scope})
    assert "https://s3.amazonaws.com/#{env_bucket}/uploads/with_scopes/1/image.png" == DefinitionWithScope.url({path, scope})
    assert_public(DefinitionWithScope, {path, scope})
    delete_and_assert_not_found(DefinitionWithScope, {path, scope})
  end

  @tag :s3
  @tag timeout: 150000
  test "put with error" do
    Application.put_env(:arc, :bucket, "unknown-bucket")
    {:error, res} = DummyDefinition.store("test/support/image.png")
    Application.put_env :arc, :bucket, env_bucket
    assert res
  end
end
