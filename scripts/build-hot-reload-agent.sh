#!/bin/bash
# 构建内置 HotReloadAgent.jar（标准 Instrumentation，无 JDWP）。
# 用法: ./scripts/build-hot-reload-agent.sh [输出路径]      默认 build/HotReloadAgent.jar
#
# Agent 只用 JDK 8 的 API（--release 8），因此用任意 JDK 8+ 编译出的包
# 都能被项目实际使用的 JDK 加载。jar 必须随 App 放进 Contents/Resources。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/HotReloadAgent.jar}"
SOURCE_ROOT="HotReloadAgent/src/main/java"
MANIFEST="HotReloadAgent/Manifest.txt"
CLASSES="build/hot-reload-agent-classes"

[ -d "$SOURCE_ROOT" ] || { echo "❌ 找不到 $SOURCE_ROOT" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "❌ 找不到 $MANIFEST" >&2; exit 1; }

if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ]; then
    JDK_HOME="$JAVA_HOME"
elif [ -x /usr/libexec/java_home ] && /usr/libexec/java_home >/dev/null 2>&1; then
    JDK_HOME="$(/usr/libexec/java_home)"
elif command -v javac >/dev/null 2>&1; then
    JDK_HOME="$(cd "$(dirname "$(command -v javac)")/.." && pwd)"
else
    echo "❌ 找不到 JDK：构建 HotReloadAgent 需要 javac（JDK 8+）。" >&2
    echo "   请安装 JDK，或设置 JAVA_HOME 后重试。" >&2
    exit 1
fi

JAVAC="$JDK_HOME/bin/javac"
JAR="$JDK_HOME/bin/jar"
[ -x "$JAVAC" ] || { echo "❌ $JAVAC 不可执行" >&2; exit 1; }
[ -x "$JAR" ] || { echo "❌ $JAR 不可执行" >&2; exit 1; }

rm -rf "$CLASSES"
mkdir -p "$CLASSES" "$(dirname "$OUT")"

# macOS 自带 bash 3.2 没有 mapfile；用 -print0 + read -d '' 逐项收集，避免空格路径问题。
SOURCES=()
while IFS= read -r -d '' file; do
    SOURCES+=("$file")
done < <(find "$SOURCE_ROOT" -name '*.java' -type f -print0)
[ "${#SOURCES[@]}" -gt 0 ] || { echo "❌ $SOURCE_ROOT 下没有 Java 源文件" >&2; exit 1; }

"$JAVAC" --release 8 -encoding UTF-8 -Xlint:-options -d "$CLASSES" "${SOURCES[@]}"
"$JAR" cfm "$OUT" "$MANIFEST" -C "$CLASSES" .

# 验证产物：Premain-Class 必须在 Manifest 里，主类必须真的打进 jar。
# 不用 unzip | grep -q：pipefail 下 grep 提前退出会让 unzip 收到 SIGPIPE 而误报失败。
MANIFEST_TEXT="$(unzip -p "$OUT" META-INF/MANIFEST.MF)"
grep -q '^Premain-Class: com.misswell.idealightrun.agent.HotReloadAgent' <<<"$MANIFEST_TEXT" \
    || { echo "❌ $OUT 缺少 Premain-Class" >&2; exit 1; }
JAR_LIST="$(unzip -l "$OUT")"
grep -q 'com/misswell/idealightrun/agent/HotReloadAgent.class' <<<"$JAR_LIST" \
    || { echo "❌ $OUT 缺少 HotReloadAgent.class" >&2; exit 1; }

echo "✅ Built $OUT ($(du -h "$OUT" | cut -f1))"
