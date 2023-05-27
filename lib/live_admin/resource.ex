defmodule LiveAdmin.Resource do
  defstruct [:schema, :config]

  import Ecto.Query
  import LiveAdmin, only: [get_config: 2, get_config: 3, repo: 0, parent_associations: 1]

  alias Ecto.Changeset

  def find!(id, resource, prefix), do: repo().get!(resource.schema, id, prefix: prefix)
  def find(id, resource, prefix), do: repo().get(resource.schema, id, prefix: prefix)

  def delete(record, config, session) do
    config
    |> get_config(:delete_with, :default)
    |> case do
      :default ->
        repo().delete(record)

      {mod, func_name, args} ->
        apply(mod, func_name, [record, session] ++ args)
    end
  end

  def list(resource, opts, session) do
    resource
    |> get_config(:list_with, :default)
    |> case do
      :default ->
        build_list(resource, opts, session.prefix)

      {mod, func_name, args} ->
        apply(mod, func_name, [resource, opts, session] ++ args)
    end
  end

  def change(resource, record \\ nil, params \\ %{})

  def change(resource, record, params) when is_struct(record) do
    build_changeset(record, resource.config, params)
  end

  def change(resource, nil, params) do
    resource.schema
    |> struct(%{})
    |> build_changeset(resource.config, params)
  end

  def create(resource, params, session) do
    resource
    |> get_config(:create_with, :default)
    |> case do
      :default ->
        resource
        |> change(nil, params)
        |> repo().insert(prefix: session.prefix)

      {mod, func_name, args} ->
        apply(mod, func_name, [params, session] ++ args)
    end
  end

  def update(record, config, params, session) do
    config
    |> get_config(:update_with, :default)
    |> case do
      :default ->
        record
        |> change(config, params)
        |> repo().update()

      {mod, func_name, args} ->
        apply(mod, func_name, [record, params, session] ++ args)
    end
  end

  def validate(changeset, config, session) do
    config
    |> get_config(:validate_with)
    |> case do
      nil -> changeset
      {mod, func_name, args} -> apply(mod, func_name, [changeset, session] ++ args)
    end
    |> Map.put(:action, :validate)
  end

  def fields(schema_or_resource, config \\ %{})

  def fields(%{schema: schema, config: config}, _), do: fields(schema, config)

  def fields(schema, config) do
    Enum.flat_map(schema.__schema__(:fields), fn field_name ->
      config
      |> get_config(:hidden_fields, [])
      |> Enum.member?(field_name)
      |> case do
        false ->
          [
            {field_name, schema.__schema__(:type, field_name),
             [immutable: get_config(config, :immutable_fields, []) |> Enum.member?(field_name)]}
          ]

        true ->
          []
      end
    end)
  end

  defp build_list(resource, opts, prefix) do
    opts =
      opts
      |> Enum.into(%{})
      |> Map.put_new(:page, 1)
      |> Map.put_new(:sort, {:asc, :id})
      |> Map.put_new(:page_size, get_config(resource, :page_size, 10))

    query =
      resource.schema
      |> limit(^opts[:page_size])
      |> offset(^((opts[:page] - 1) * opts[:page_size]))
      |> order_by(^[opts[:sort]])
      |> preload(^preloads(resource))

    query =
      opts
      |> Enum.reduce(query, fn
        {:search, q}, query when byte_size(q) > 0 ->
          apply_search(query, q, fields(resource))

        _, query ->
          query
      end)

    {
      repo().all(query, prefix: prefix),
      repo().aggregate(query |> exclude(:limit) |> exclude(:offset), :count, prefix: opts[:prefix])
    }
  end

  defp apply_search(query, q, fields) do
    q
    |> String.split(~r{[^\s]*:}, include_captures: true, trim: true)
    |> case do
      [q] ->
        Enum.reduce(fields, query, fn {field_name, _, _}, query ->
          or_where(
            query,
            [r],
            ilike(fragment("CAST(? AS text)", field(r, ^field_name)), ^"%#{q}%")
          )
        end)

      field_queries ->
        field_queries
        |> Enum.map(&String.trim/1)
        |> Enum.chunk_every(2)
        |> Enum.reduce(query, fn
          [field_key, q], query ->
            fields
            |> Enum.find_value(fn {field_name, _, _} ->
              if "#{field_name}:" == field_key, do: field_name
            end)
            |> case do
              nil ->
                query

              field_name ->
                or_where(
                  query,
                  [r],
                  ilike(fragment("CAST(? AS text)", field(r, ^field_name)), ^"%#{q}%")
                )
            end

          _, query ->
            query
        end)
    end
  end

  defp build_changeset(record = %schema{}, config, params) do
    schema
    |> fields(config)
    |> Enum.reduce(Changeset.cast(record, params, []), fn
      {field_name, {_, Ecto.Embedded, meta}, _}, changeset ->
        if Map.get(params, to_string(field_name)) == "delete" do
          Changeset.put_embed(
            changeset,
            field_name,
            if(meta.cardinality == :many, do: [], else: nil)
          )
        else
          Changeset.cast_embed(changeset, field_name,
            with: fn embed, params -> build_changeset(embed, %{}, params) end
          )
        end

      {field_name, type, opts}, changeset ->
        unless Keyword.get(opts, :immutable, false) do
          changeset = Changeset.cast(changeset, params, [field_name])

          if type == :map do
            Changeset.update_change(changeset, field_name, &parse_map_param/1)
          else
            changeset
          end
        else
          changeset
        end
    end)
  end

  defp parse_map_param(param = %{}) do
    param
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Map.new(fn {_, %{"key" => key, "value" => value}} -> {key, value} end)
  end

  defp parse_map_param(param), do: param

  defp preloads(resource) do
    resource.config
    |> Map.get(:preload)
    |> case do
      nil -> resource.schema |> parent_associations() |> Enum.map(& &1.field)
      {m, f, a} -> apply(m, f, [resource | a])
      preloads when is_list(preloads) -> preloads
    end
  end
end
