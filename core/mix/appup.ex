# Copyright(c) 2015-2020 ACCESS CO., LTD. All rights reserved.

defmodule AntikytheraCore.Release.Appup do
  @moduledoc """
  Generates a .appup file for the given application, start version, and upgrade version.

  The appup file generated by `make/5` is much simpler than that by similar appup generation tools,
  as `make/5` does not use `update` instruction (which is called "synchronized code replacement").
  Synchronized code replacement (which uses `code_change/3`) is risky because

  - It's difficult to get it right, difficult to test.
  - Suspending target processes entails traversing the whole supervision tree.
    All processes in the tree must respond to system messages in a timely manner.
      - Processes governed by some libraries might not properly handle system messages;
        if it's the case all OTP applications will be restarted by `:init.restart()`.
      - Some process might not respond in a timely fashion; resulting in brutal kill of the unresponsive process.
      - Suspending handling of non-system messages might cause performance issues.

  Therefore we simply don't use OTP's code change mechanism;
  to change data format of process state we
  - implement callbacks to check/convert the data format version, or
  - avoid hot code upgrade and replace the working instances with new ones.

  On the other hand, `make/5` automatically resolves interdependencies between changed modules (which other tools don't).

  ## Parameters for `make/5`

  - `name`  : the application name as an atom
  - `v1`    : the start version, such as "0.0.1"
  - `v2`    : the upgrade version, such as "0.0.2"
  - `v1_dir`: the path to the v1 artifacts (rel/<app>/lib/<app>-0.0.1)
  - `v2_dir`: the path to the v2 artifacts (_build/prod/lib/<app>)
  """
  def make(name, v1, v2, v1_dir, v2_dir) do
    validate_version_in_app_file(name, v1, v1_dir)
    validate_version_in_app_file(name, v2, v2_dir)
    make_appup(name, v1, v1_dir, v2, v2_dir)
  end

  defp validate_version_in_app_file(name, v, dir) do
    version_in_app_file = AntikytheraCore.Version.read_from_app_file(dir, name)
    if version_in_app_file != v do
      raise "Incorrect version #{version_in_app_file} in .app file under '#{dir}', expecting #{v}"
    end
  end

  defp make_appup(name, v1, v1_dir, v2, v2_dir) do
    v1_charlist = String.to_charlist(v1)
    v2_charlist = String.to_charlist(v2)
    v1_ebin_dir = Path.join(v1_dir, "ebin") |> String.to_charlist()
    v2_ebin_dir = Path.join(v2_dir, "ebin") |> String.to_charlist()
    {only_v1, only_v2, diff_pairs} = :beam_lib.cmp_dirs(v1_ebin_dir, v2_ebin_dir)
    diff = reject_unchanged_modules(diff_pairs) |> Enum.map(fn {_f1, f2} -> f2 end)
    file_content = {
      v2_charlist,
      [
        {v1_charlist, generate_instructions(only_v2, diff, only_v1)}
      ],
      [
        {v1_charlist, generate_instructions(only_v1, diff, only_v2)}
      ],
    }
    v2_appup_path = Path.join([v2_dir, "ebin", "#{name}.appup"])
    file_content_string = :io_lib.fwrite('~p.\n', [file_content]) |> List.to_string()
    File.write!(v2_appup_path, file_content_string)
  end

  defp reject_unchanged_modules(path_pairs) do
    Enum.filter(path_pairs, fn {old_path, new_path} ->
      module_changed?(old_path, new_path)
    end)
  end

  defp module_changed?(old_path, new_path) do
    # `:beam_lib.cmp_dirs/2` can't ignore trivial changes such as debug-info-only changes.
    # In order not to waste CPU, we shouldn't include these modules in .appup file.
    {:ok, module_name, old_chunks} = :beam_lib.all_chunks(old_path)
    {:ok, _          , new_chunks} = :beam_lib.all_chunks(new_path)
    if length(old_chunks) != length(new_chunks) do
      true
    else
      changed_chunk_names =
        Enum.zip(Enum.sort(old_chunks), Enum.sort(new_chunks))
        |> Enum.filter(fn {{_, ov}, {_, nv}} -> ov != nv end)
        |> Enum.map(fn {{k, _}, _} -> k end)
      if changed_chunk_names == ['Dbgi'] do
        IO.puts("#{inspect(module_name)} is excluded from .appup file, because only Dbgi chunk is changed.")
        false
      else
        true
      end
    end
  end

  defp generate_instructions(added, diff, deleted) do
    # add_module instructions must precede load_module instructions
    List.flatten([
      Enum.map(added, fn f -> {:add_module, read_module_name(f)} end),
      generate_instructions_for_changed_modules(diff),
      Enum.map(deleted, fn f -> {:delete_module, read_module_name(f)} end),
    ])
  end

  defp generate_instructions_for_changed_modules(files) do
    # module load instructions are reordered based on their interdependencies by :systools
    # when translating high-level instructions into low-level ones,
    # i.e., when making relup files (for antikythera instance) or when loading .appup files (for gears).
    changed_modules = MapSet.new(files, &read_module_name/1)
    Enum.map(files, &generate_instruction_for_changed_module(&1, changed_modules))
  end

  defp generate_instruction_for_changed_module(file, changed_modules) do
    {:ok, {module_name, [atoms: atoms_with_indices]}} = :beam_lib.chunks(file, [:atoms])
    atoms = Enum.map(atoms_with_indices, fn {_, a} -> a end) |> List.delete(module_name)
    dep_mods = Enum.filter(atoms, &(&1 in changed_modules))
    {:load_module, module_name, dep_mods}
  end

  defp read_module_name(file) do
    :beam_lib.info(file) |> Keyword.fetch!(:module)
  end
end
