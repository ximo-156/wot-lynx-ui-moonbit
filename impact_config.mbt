///|
/// Default MoonImpact scope and test inventory. No project-local executable
/// configuration is loaded. Filesystem reads are opt-in by wrapper name.
pub fn impact_default_config() -> ImpactConfig {
  let tests : Array[String] = []
  for ext in ["ts", "tsx", "js", "jsx", "mts", "cts", "mjs", "cjs"] {
    tests.push("**/*.spec.\{ext}")
    tests.push("**/*.test.\{ext}")
  }
  {
    includes: [],
    excludes: ["**/*.min.js"],
    tests,
    aliases: [],
    file_readers: [],
    dependencies: [],
    global_inputs: [
      "package.json", "pnpm-lock.yaml", "package-lock.json", "yarn.lock", "bun.lock",
      "bun.lockb", "**/tsconfig*.json", "**/vite.config.*", "**/vitest.config.*",
      "**/vitest.workspace.*", "moonimpact.json", "**/setup.*", "**/setupTests.*",
      "**/.env*", "src/main.ts", "src/App.vue",
    ],
    style_load_paths: [],
    skip_dirs: [
      ".git", "node_modules", "dist", "target", "_build", ".mooncakes", "coverage",
      ".rspeedy", ".vitepress", ".preview",
    ],
    runner_dir: "",
    max_source_bytes: 2000000,
  }
}

///|
/// Read a strictly typed string array, retaining significant filename spaces.
fn impact_strings(
  obj : Map[String, Json],
  key : String,
  fallback : Array[String],
) -> Array[String] raise {
  let items = match obj.get(key) {
    None => return fallback.copy()
    Some(Json::Array(items)) => items
    _ => raise Failure("moonimpact config: \{key} must be an array of strings")
  }
  let result : Array[String] = []
  for item in items {
    match item {
      Json::String(text) if text != "" && !text.contains("\u{0}") =>
        if !result.contains(text) {
          result.push(text)
        }
      _ =>
        raise Failure(
          "moonimpact config: \{key} entries must be nonempty strings",
        )
    }
  }
  result
}

///|
/// Root-relative portable path validation. Unlike module resolution this must
/// reject every .. segment rather than collapse it. Input paths are never
/// trimmed, and neither absolute paths nor Windows separators are accepted.
fn impact_path(path : String, allow_root : Bool) -> String raise {
  let chars = path.to_array()
  let drive = chars.length() >= 2 &&
    chars[1] == ':' &&
    (
      (chars[0] >= 'a' && chars[0] <= 'z') ||
      (chars[0] >= 'A' && chars[0] <= 'Z')
    )
  if path.contains("\\") || drive {
    raise Failure("moonimpact: use a root-relative /-separated path: \{path}")
  }
  if allow_root && (path == "" || path == ".") {
    return ""
  }
  normalize_relative(path)
}

///|
fn impact_config_string(obj : Map[String, Json], key : String) -> String raise {
  match obj.get(key) {
    Some(Json::String(text)) => text
    _ => raise Failure("moonimpact config: \{key} must be a string")
  }
}

///|
/// Validate even a configuration constructed through the library API.
fn impact_validate_config(config : ImpactConfig) -> Unit raise {
  for
    patterns in [
      config.includes,
      config.excludes,
      config.tests,
      config.global_inputs,
    ] {
    for pattern in patterns {
      validate_glob(pattern)
    }
  }
  if config.tests.is_empty() {
    raise Failure("moonimpact config: tests must contain at least one glob")
  }
  if config.max_source_bytes <= 0 {
    raise Failure("moonimpact config: max_source_bytes must be positive")
  }
  let aliases : Set[String] = Set([])
  for (prefix, target) in config.aliases {
    if prefix == "" ||
      prefix.has_prefix(".") ||
      prefix.contains("*") ||
      prefix.contains("?") ||
      prefix.contains("#") {
      raise Failure(
        "moonimpact config: alias prefix must be a literal module prefix",
      )
    }
    let normalized = impact_path(prefix, false)
    if aliases.contains(normalized) {
      raise Failure("moonimpact config: duplicate alias prefix: \{prefix}")
    }
    aliases.add(normalized)
    ignore(impact_path(target, true))
  }
  for reader in config.file_readers {
    let chars = reader.to_array()
    if chars.is_empty() ||
      !is_ident_start(chars[0]) ||
      !chars.iter().all(is_ident_char) {
      raise Failure(
        "moonimpact config: file_readers must be simple JS identifiers",
      )
    }
  }
  for edge in config.dependencies {
    ignore(impact_path(edge.dependency, false))
    ignore(impact_path(edge.dependent, false))
  }
  // Sass load paths are root-relative directories, mirroring the build's
  // loadPaths option. They never contain globs and never escape the root.
  for load_path in config.style_load_paths {
    if load_path.contains("*") || load_path.contains("?") {
      raise Failure(
        "moonimpact config: style_load_paths must be directories, not globs: \{load_path}",
      )
    }
    ignore(impact_path(load_path, true))
  }
  // The runner directory is where the test runner is configured. It is a
  // plain root-relative directory, never a glob or an absolute path.
  if config.runner_dir.contains("*") || config.runner_dir.contains("?") {
    raise Failure(
      "moonimpact config: runner_dir must be a directory, not a glob: \{config.runner_dir}",
    )
  }
  // Noise directories are plain names; a project may replace the default list
  // when its tests genuinely read conventional build output.
  for name in config.skip_dirs {
    if name == "" ||
      name.contains("/") ||
      name.contains("\\") ||
      name.contains("*") ||
      name.contains("?") ||
      name == "." ||
      name == ".." {
      raise Failure(
        "moonimpact config: skip_dirs entries must be plain directory names: \{name}",
      )
    }
  }
}

///|
/// Parse inert JSON configuration. Unknown fields, duplicate JSON keys and
/// invalid paths are rejected before scanning. This schema is independent of
/// moonlint rules and deliberately has no command execution or extends field.
pub fn parse_impact_config(source : String) -> ImpactConfig raise {
  let json = @json.parse(
    source,
    max_nesting_depth=32,
    reject_duplicate_keys=true,
  ) catch {
    _ => raise Failure("moonimpact config: invalid JSON or duplicate keys")
  }
  let obj = match json {
    Json::Object(obj) => obj
    _ => raise Failure("moonimpact config: root must be an object")
  }
  match
    config_fields(
      obj,
      [
        "version", "include", "exclude", "tests", "aliases", "file_readers", "dependencies",
        "global_inputs", "style_load_paths", "skip_dirs", "runner_dir", "max_source_bytes",
      ],
      "moonimpact config",
    ) {
    Some(message) => raise Failure(message)
    None => ()
  }
  match obj.get("version") {
    None | Some(Json::Number(1.0, ..)) => ()
    _ => raise Failure("moonimpact config: version must be 1")
  }
  let defaults = impact_default_config()
  let aliases : Array[(String, String)] = []
  match obj.get("aliases") {
    None => ()
    Some(Json::Object(entries)) =>
      for (prefix, value) in entries {
        let target = match value {
          Json::String(text) => impact_path(text, true)
          _ => raise Failure("moonimpact config: alias targets must be strings")
        }
        aliases.push((prefix, target))
      }
    _ => raise Failure("moonimpact config: aliases must be an object")
  }
  aliases.sort_by((a, b) => a.0.compare(b.0))
  let dependencies : Array[ImpactEdge] = []
  match obj.get("dependencies") {
    None => ()
    Some(Json::Array(entries)) =>
      for item in entries {
        let fields = match item {
          Json::Object(fields) => fields
          _ => raise Failure("moonimpact config: dependency must be an object")
        }
        match config_fields(fields, ["dependent", "dependency"], "dependency") {
          Some(message) => raise Failure(message)
          None => ()
        }
        dependencies.push({
          dependent: impact_path(
            impact_config_string(fields, "dependent"),
            false,
          ),
          dependency: impact_path(
            impact_config_string(fields, "dependency"),
            false,
          ),
          kind: "explicit",
          line: 0,
          column: 0,
        })
      }
    _ => raise Failure("moonimpact config: dependencies must be an array")
  }
  let max_source_bytes = match obj.get("max_source_bytes") {
    None => defaults.max_source_bytes
    Some(value) =>
      match config_check_integer(value, "max_source_bytes") {
        Ok(n) => n
        Err(ConfigError(message)) =>
          raise Failure("moonimpact config: \{message}")
      }
  }
  let runner_dir = match obj.get("runner_dir") {
    None => defaults.runner_dir
    Some(Json::String(text)) => impact_path(text, true)
    _ => raise Failure("moonimpact config: runner_dir must be a string")
  }
  let config : ImpactConfig = {
    includes: impact_strings(obj, "include", defaults.includes),
    excludes: impact_strings(obj, "exclude", defaults.excludes),
    tests: impact_strings(obj, "tests", defaults.tests),
    aliases,
    file_readers: impact_strings(obj, "file_readers", defaults.file_readers),
    dependencies,
    global_inputs: impact_strings(obj, "global_inputs", defaults.global_inputs),
    style_load_paths: impact_strings(
      obj,
      "style_load_paths",
      defaults.style_load_paths,
    ),
    skip_dirs: impact_strings(obj, "skip_dirs", defaults.skip_dirs),
    runner_dir,
    max_source_bytes,
  }
  impact_validate_config(config)
  config
}
