///|
/// Tests for Vue single-file-component template usage extraction.

///|
fn vue_sample() -> String {
  #|<template>
  #|  <wd-img :src="logoQuan" />
  #|  <view v-if="canCancel(item)" @click="onTap">{{ label }}</view>
  #|  <view class="static-text">plain</view>
  #|</template>
  #|<script setup lang="ts">
  #|import logoQuan from './logo.png'
  #|const label = 'x'
  #|</script>
  #|
}

///|
test "vue template bindings contribute identifier usages" {
  let names = vue_template_usages(vue_sample()).map(u => u.name)
  // `:src`, `v-if` and `@click` values are expressions.
  assert_true(names.contains("logoQuan"))
  assert_true(names.contains("canCancel"))
  assert_true(names.contains("item"))
  assert_true(names.contains("onTap"))
  // A static attribute value is text, not an expression.
  assert_false(names.contains("static-text"))
}

///|
test "vue template scan ignores binding-shaped strings in script" {
  let src =
    #|<template>
    #|<view>x</view>
    #|</template>
    #|<script>
    #|const fake = ':src="notAUsage"'
    #|</script>
    #|
  assert_false(vue_template_usages(src).map(u => u.name).contains("notAUsage"))
}

///|
test "parse_source_for adds template usages only for vue files" {
  let src = vue_sample()
  let vue = parse_source_for("src/Page.vue", src)
  assert_true(vue.used.map(u => u.name).contains("logoQuan"))
  // The same text read as a plain .ts file is not template-expanded.
  let ts = parse_source_for("src/page.ts", src)
  assert_false(ts.used.map(u => u.name).contains("logoQuan"))
}

///|
test "a binding used only in a template is not an unused import" {
  let rules = [
    structural_rule("imports/no-unused-imports", NoUnusedImports, [".vue"]),
  ]
  let files : Array[(String, String)] = [
    (
      "src/Page.vue",
      "<template>\n<wd-img :src=\"logoQuan\" />\n</template>\n<script setup lang=\"ts\">\nimport logoQuan from './logo.png'\n</script>\n",
    ),
  ]
  assert_eq(analyze(build_index(files), rules).length(), 0)
}
