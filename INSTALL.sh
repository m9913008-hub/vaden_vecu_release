#!/usr/bin/env bash
# 泛用安裝器：將 <專案>_<YYYYMMDD>_<版號>.tar.zst|tar.xz 解開並安裝到 $INSTALL_HOME/<專案>。
# 流程：若壓縮內含 *.service，於安裝 lib 之 .deb 前先停止 /etc/systemd/system 內對應且運行中之單元 →
#       離線（可選）安裝壓縮內 lib 之 .deb → rsync 專案樹 → 寫入 INI 版號 → 執行重啟腳本。
# 與 PACKAGE.sh 產物相容：壓縮內頂層為 <專案>_<日期>_<版號>/，其下含 lib/（可選）與 <專案>/。
# 建議與壓縮檔一併放在 /home/pi/update/（或其他目錄），以 root 執行。
#
# 用法:
#   sudo -E ./INSTALL.sh /path/to/myapp_20260424_001.tar.zst
#   sudo -E ./INSTALL.sh                                    # 使用同目錄下**唯一**一個 .tar.zst 或 .tar.xz
#
# 環境變數:
#   INSTALL_HOME   安裝上層目錄（預設：執行 sudo 前之使用者的家目錄，例如 /home/pi；勿尾隨 /）
#   TARGET_USER   專樹屬主（預設：INSTALL_HOME 對應之使用者，或 SUDO_USER，或 pi）
#   TARGET_GROUP  專樹屬性（預設與 TARGET_USER 同）
#   OFFLINE=1  （預設） 僅以壓縮內之 .deb 安裝，不讓 apt 走網路；打包時需含完整相依關閉包。
#   OFFLINE=0          若目標有網可設為 0，讓 apt 有機會下載補足相依（一般不建議與本包混用）。
#   SKIP_APT=1   不執行 lib 內 .deb
#   SKIP_RESTART=1  不執行重啟腳本
#   SKIP_INI=1  不寫入 INI 版號
#   INSTALL_RECORD_FILE  日誌路徑（預設為本腳本同目錄之 record.txt，每次執行覆寫、不疊寫上輪）
#
# 泛用化（非 ai_service 專案可調）:
#   INSTALL_INI_REL       相對於安裝目錄 $DEST 之 INI 路徑（預設 data/device.ini）
#   INSTALL_INI_SECTION   區段名稱（預設 System）
#   INSTALL_INI_VERSION_KEY  版號鍵名（預設 version）
#   INSTALL_INI_EXTRA_DEFAULTS=1  為 1 且區段為 System 時，若缺欄位則補 iniPath、ip（ai_service 相容；其他專案可設 0 僅寫版號）
#   INSTALL_RESTART_REL   相對於 $DEST 之重啟腳本（預設 restart.sh）
#   INSTALL_HELP_URL      apt 失敗時訊息內之說明連結或路徑（預設：doc/pack-and-install.md）
#
# install.manifest（可選，位於壓縮檔頂層目錄，與 lib/、<PROJECT>/ 同層）:
#   僅 KEY=value；若執行前未設定對應環境變數，則由 INSTALL.sh 讀取並套用（見與 PACKAGE 同目錄之 install.manifest 範例）。
#
set -euo pipefail

# 解壓暫存路徑須為腳本全域變數：EXIT trap 在 MAIN 函式結束後才執行，若用 local TMP 則 trap 內 ${TMP} 在 set -u 下會變未設定而失敗。
__INSTALL_EXTRACT_DIR=""

_install_home_default() {
	if [[ -n "${INSTALL_HOME:-}" ]]; then
		printf '%s' "$INSTALL_HOME"
		return
	fi
	local u="${SUDO_USER:-${USER:-pi}}"
	if [[ -n "$u" && "$u" != root ]]; then
		getent passwd "$u" | cut -d: -f6
		return
	fi
	printf '/home/pi'
}

# 由壓縮檔主檔名（無副檔名）解析：<專案>_<YYYYMMDD>_<版號>
_parse_stem() {
	local stem="$1"
	if [[ "$stem" =~ ^(.+)_([0-9]{8})_(.+)$ ]]; then
		_PROJECT="${BASH_REMATCH[1]}"
		_DATE_YYYYMMDD="${BASH_REMATCH[2]}"
		_VERSION_TAG="${BASH_REMATCH[3]}"
		return 0
	fi
	return 1
}

_version_for_ini() {
	# 由 YYYYMMDD 與版號節 組成 vYYYY.MM.DD.xxx
	local ymd="$1" tag="$2"
	local y="${ymd:0:4}" m="${ymd:4:2}" d="${ymd:6:2}"
	printf 'v%s.%s.%s.%s' "$y" "$m" "$d" "$tag"
}

# 佈建以 DEST.bak.<n> 備份（n 由 1 遞增），僅保留最新若干筆（僅計入 1–9 位數之 .bak.n；舊版十位數 .bak.<epoch> 不納入計數與刪除）
_next_bak_num() {
	local dest="$1" max_n=0 n p
	shopt -s nullglob
	for p in "$dest.bak."*; do
		n="${p#"${dest}.bak."}"
		[[ "$n" =~ ^[0-9]{1,9}$ ]] || continue
		((10#$n > max_n)) && max_n=$((10#$n))
	done
	shopt -u nullglob
	echo $((max_n + 1))
}

_prune_bak_backups() {
	local dest="$1"
	local max_keep="${2:-2}"
	local p n oldest oldest_n
	[[ -n "$dest" ]] || return 0
	[[ "$max_keep" -ge 1 ]] || return 0
	while true; do
		shopt -s nullglob
		local -a baks=()
		for p in "$dest.bak."*; do
			n="${p#"${dest}.bak."}"
			[[ "$n" =~ ^[0-9]{1,9}$ ]] || continue
			baks+=("$p")
		done
		shopt -u nullglob
		((${#baks[@]} <= max_keep)) && return 0
		oldest= oldest_n=
		for p in "${baks[@]}"; do
			n="${p#"${dest}.bak."}"
			if [[ -z $oldest_n ]] || ((10#$n < 10#$oldest_n)); then
				oldest_n=$n
				oldest=$p
			fi
		done
		[[ -n "$oldest" ]] || return 0
		rm -rf -- "$oldest" 2>/dev/null || true
	done
}

# 單元於 /etc/systemd/system 有設定（本體、連結或 .d 目錄）
_systemd_unit_configured_in_etc() {
	local u="$1"
	[[ -e "/etc/systemd/system/$u" || -L "/etc/systemd/system/$u" || -d "/etc/systemd/system/${u}.d" ]]
}

# 壓縮內若有 *.service，在安裝 lib/.deb 前先停止：與該檔名相同、且於 /etc/systemd/system 有對應、且目前 active 的單元
_stop_bundle_services_before_deb_install() {
	local srcroot="$1"
	local path base
	declare -A seen=()
	while IFS= read -r -d '' path; do
		base="$(basename -- "$path")"
		[[ "$base" == *.service ]] || continue
		[[ -n "${seen[$base]:-}" ]] && continue
		seen[$base]=1
		if _systemd_unit_configured_in_etc "$base" && systemctl is-active --quiet "$base" 2>/dev/null; then
			printf '[INSTALL] 安裝 lib/.deb 前先停止運行中之 %s（壓縮內含同名 .service，且於 /etc/systemd/system 有設定）\n' "$base" >&2
			systemctl stop "$base" 2>/dev/null || true
		fi
	done < <(find "$srcroot" -type f -name '*.service' -print0 2>/dev/null)
}

_load_install_manifest() {
	local mf="$1"
	[[ -f "$mf" ]] || return 0
	printf '[INSTALL] 讀取 install.manifest（僅套用尚未設定之環境變數）: %s\n' "$mf" >&2
	local line key val
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[[ -z "$line" || "$line" == \#* ]] && continue
		if [[ "$line" == *'='* ]] && [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
			key="${line%%=*}"
			val="${line#*=}"
			val="${val#"${val%%[![:space:]]*}"}"
			val="${val%"${val##*[![:space:]]}"}"
			case "$key" in
				INSTALL_INI_REL) [[ -z "${INSTALL_INI_REL:-}" ]] && INSTALL_INI_REL="$val" ;;
				INSTALL_INI_SECTION) [[ -z "${INSTALL_INI_SECTION:-}" ]] && INSTALL_INI_SECTION="$val" ;;
				INSTALL_INI_VERSION_KEY) [[ -z "${INSTALL_INI_VERSION_KEY:-}" ]] && INSTALL_INI_VERSION_KEY="$val" ;;
				INSTALL_INI_EXTRA_DEFAULTS) [[ -z "${INSTALL_INI_EXTRA_DEFAULTS:-}" ]] && INSTALL_INI_EXTRA_DEFAULTS="$val" ;;
				INSTALL_RESTART_REL) [[ -z "${INSTALL_RESTART_REL:-}" ]] && INSTALL_RESTART_REL="$val" ;;
				INSTALL_HELP_URL) [[ -z "${INSTALL_HELP_URL:-}" ]] && INSTALL_HELP_URL="$val" ;;
				*) ;; # 略過未知鍵
			esac
		fi
	done <"$mf"
}

_extract_one_toplevel() {
	local ar="$1" dest="$2"
	case "$ar" in
		*.tar.zst|*.tzst)
			if ! zstd -dc --force -- "$ar" 2>/dev/null | tar -x -C "$dest" -f -; then
				if ! tar -I zstd -xf "$ar" -C "$dest" 2>/dev/null; then
					tar -xf "$ar" -C "$dest" 2>/dev/null || {
						printf '解壓失敗: %s（建議: apt install -y zstd）\n' "$ar" >&2
						return 1
					}
				fi
			fi
			;;
		*.tar.xz|*.txz)
			tar -xJf "$ar" -C "$dest"
			;;
		*)
			printf '不支援的副檔名: %s\n' "$ar" >&2
			return 1
			;;
	esac
}

MAIN() {
	if [[ "${EUID:-0}" -ne 0 ]]; then
		exec sudo -E -- "$0" "$@"
	fi

	# 過程與錯誤一併寫入本腳本同目錄之 record.txt（不 append 跨次執行，每次從新檔寫起）
	local _script_dir
	_script_dir="$(cd "$(dirname "$0")" && pwd)"
	local RECORD_FILE="${INSTALL_RECORD_FILE:-$_script_dir/record.txt}"
	: >"$RECORD_FILE"
	{
		printf '=== INSTALL.sh 紀錄 ===\n'
		printf '時間: %s\n' "$(date -Iseconds 2>/dev/null || date)"
		printf '主機: %s\n' "$(hostname 2>/dev/null || true)"
		# 逐引數 %q；勿用 printf '---...'（格式字串以 - 開頭時，部分 printf 會誤判為選項）
		printf '指令: '
		local __a
		printf '%q' "$0"
		for __a; do
			printf ' '
			printf '%q' "$__a"
		done
		printf '\n'
		printf '%s\n' '---'
	} | tee -a "$RECORD_FILE"
	exec > >(tee -a "$RECORD_FILE") 2>&1

	local AR="${1:-}"
	if [[ -z "$AR" ]]; then
		local d here cnt
		here="$(cd "$(dirname "$0")" && pwd)"
		cnt=0
		shopt -s nullglob
		for f in "$here"/*.tar.zst "$here"/*.tar.xz; do
			AR="$f"
			cnt=$((cnt + 1))
		done
		shopt -u nullglob
		if [[ "$cnt" -ne 1 ]]; then
			printf '請指定單一壓縮檔，或將本腳本與**一個** .tar.zst 放在同一目錄: %s\n' "$0" >&2
			exit 1
		fi
		printf '使用同目錄壓縮檔: %s\n' "$AR" >&2
	fi

	[[ -f "$AR" ]] || {
		printf '找不到: %s\n' "$AR" >&2
		exit 1
	}
	AR="$(cd "$(dirname "$AR")" && pwd)/$(basename "$AR")"

	local stem
	stem=$(basename "$AR")
	stem="${stem%.tar.zst}"
	stem="${stem%.tar.xz}"
	if ! _parse_stem "$stem"; then
		printf '檔名需為: <專案名稱>_<YYYYMMDD>_<版號>.tar.zst 或 .tar.xz\n' >&2
		printf '目前: %s\n' "$AR" >&2
		exit 1
	fi

	_PROJECT="${_PROJECT:-}"
	_DATE_YYYYMMDD="${_DATE_YYYYMMDD:-}"
	_VERSION_TAG="${_VERSION_TAG:-}"
	local ROOT_NAME="${_PROJECT}_${_DATE_YYYYMMDD}_${_VERSION_TAG}"
	local VERSION_INI
	VERSION_INI="$(_version_for_ini "$_DATE_YYYYMMDD" "$_VERSION_TAG")"

	INSTALL_HOME="$(_install_home_default)"
	INSTALL_HOME="${INSTALL_HOME%/}"
	if [[ -z "${TARGET_USER:-}" ]]; then
		TARGET_USER="${SUDO_USER:-pi}"
		[[ "$TARGET_USER" == root ]] && TARGET_USER=pi
	fi
	: "${TARGET_GROUP:=${TARGET_USER}}"

	local DEST="${INSTALL_HOME}/${_PROJECT}"
	__INSTALL_EXTRACT_DIR="$(mktemp -d /tmp/pkg_install.XXXXXX)"
	trap '[[ -n "${__INSTALL_EXTRACT_DIR:-}" ]] && rm -rf -- "${__INSTALL_EXTRACT_DIR}"' EXIT

	_extract_one_toplevel "$AR" "$__INSTALL_EXTRACT_DIR" || exit 1

	local SRCROOT="${__INSTALL_EXTRACT_DIR}/${ROOT_NAME}"
	if [[ ! -d "$SRCROOT" ]]; then
		# 若最上層單一資料夾名稱不完全一致，取第一個子目錄
		local one=""
		while IFS= read -r -d '' d; do
			one="$d"
		done < <(find "$__INSTALL_EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
		if [[ -n "$one" ]]; then
			SRCROOT="$one"
		else
			printf '解壓後找不到預期目錄: %s\n' "$ROOT_NAME" >&2
			exit 1
		fi
	fi

	_load_install_manifest "$SRCROOT/install.manifest"

	# 3.1 lib/*.deb
	if [[ "${SKIP_APT:-0}" != "1" ]] && [[ -d "$SRCROOT/lib" ]]; then
		shopt -s nullglob
		local debs=()
		if [[ -d "$SRCROOT/lib/debs" ]]; then
			debs=( "$SRCROOT"/lib/debs/*.deb )
		else
			debs=( "$SRCROOT"/lib/*.deb )
		fi
		shopt -u nullglob
		if ((${#debs[@]})); then
			_stop_bundle_services_before_deb_install "$SRCROOT"
			export DEBIAN_FRONTEND=noninteractive
			apt_get_offline=( )
			if [[ "${OFFLINE:-1}" == "1" ]]; then
				# 不啟用網路，僅用本機/已列於指令列的 .deb（與 upd_ai 離線佈建一致之期待）
				apt_get_offline+=(
					-o "Acquire::http::Enabled=false"
					-o "Acquire::https::Enabled=false"
					-o "Acquire::ftp::Enabled=false"
					-o "Acquire::Languages=none"
					# 避免觸發 cdrom 掃描延遲（可選）
					-o "Acquire::cdrom::AutoDetect=false"
				)
				printf '[INSTALL] 離線模式：僅安裝壓縮內之 .deb（請確保已含完整相依關）\n' >&2
			else
				printf '[INSTALL] OFFLINE=0：若相依不足，apt 或將嘗試上網下載\n' >&2
			fi
			# 濾除 dpkg「Reading database …」行，不寫入 record；以 PIPESTATUS[0] 判 apt 成敗
			apt-get install -y \
				"${apt_get_offline[@]}" \
				-o "Dpkg::Options::=--force-confold" \
				--allow-downgrades \
				--allow-change-held-packages \
				--reinstall \
				--no-install-recommends \
				"${debs[@]}" 2>&1 | sed '/Reading database/ d'
			if [[ "${PIPESTATUS[0]:-1}" -ne 0 ]]; then
				local _help="${INSTALL_HELP_URL:-doc/pack-and-install.md}"
				printf 'apt 安裝失敗。若為離線，請在打包機把相依之 .deb 一併放入 lib/debs/ 後再打壓。說明見: %s\n' "$_help" >&2
				exit 1
			fi
		else
			printf 'lib 內未見 .deb。離線佈建時建議在 lib/debs/ 內納入完整 .deb 集後再執行本腳本。\n' >&2
		fi
	else
		printf '略過 .deb 安裝（無 lib/ 或 SKIP_APT=1）\n' >&2
	fi

	# 3.2 佈建專案：保留權限位元，再改屬主為 TARGET_USER
	install -d -m 0755 -o root -g root -- "$INSTALL_HOME" 2>/dev/null || true
	if [[ -d "$DEST" ]]; then
		local bak="${DEST}.bak.$(_next_bak_num "$DEST")"
		printf '已存在 %s，備份至 %s\n' "$DEST" "$bak" >&2
		mv -- "$DEST" "$bak" 2>/dev/null || true
		_prune_bak_backups "$DEST" 2
	fi
	local PSRC="${SRCROOT}/${_PROJECT}"
	[[ -d "$PSRC" ]] || {
		printf '壓縮內需含專案目錄: %s/（在 %s 之下）\n' "$_PROJECT" "$ROOT_NAME" >&2
		exit 1
	}
	mkdir -p -- "$DEST"
	rsync -aH --no-inc-recursive -- "${PSRC}/" "${DEST}/"
	# 模式由 rsync 保留；屬性改為目標使用者
	chown -R "${TARGET_USER}:${TARGET_GROUP}" -- "$DEST"

	# 3.4 INI 版號（須早於 3.3 啟動；路徑／區段／鍵名可環境變數覆寫以適用其他專案）
	if [[ "${SKIP_INI:-0}" != "1" ]]; then
		local _ini_rel="${INSTALL_INI_REL:-data/device.ini}"
		local _ini_sec="${INSTALL_INI_SECTION:-System}"
		local _ini_vkey="${INSTALL_INI_VERSION_KEY:-version}"
		local _ini_extra="${INSTALL_INI_EXTRA_DEFAULTS:-1}"
		local ini="${DEST}/${_ini_rel}"
		python3 - "$ini" "$VERSION_INI" "$_ini_sec" "$_ini_vkey" "$_ini_extra" <<'PY'
import configparser, sys, os
path, ver, sec, vkey, extra = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
cfg = configparser.ConfigParser()
cfg.optionxform = str
if os.path.isfile(path):
	cfg.read(path, encoding="utf-8")
if not cfg.has_section(sec):
	cfg.add_section(sec)
if extra == "1" and sec == "System":
	if not (cfg.get("System", "iniPath", fallback="") or cfg.get("System", "inipath", fallback="")).strip():
		cfg.set("System", "iniPath", path)
	if not (cfg.get("System", "ip", fallback="") or "").strip():
		cfg.set("System", "ip", "172.16.100.10")
cfg.set(sec, vkey, ver)
with open(path, "w", encoding="utf-8") as f:
	cfg.write(f)
print(f"已寫入 [{sec}] {vkey} = {ver} -> {path}")
PY
		local _data_dir
		_data_dir="$(dirname -- "$ini")"
		if [[ "$_data_dir" != "$DEST" && "$_data_dir" != . ]]; then
			chown -R "${TARGET_USER}:${TARGET_GROUP}" -- "$_data_dir" 2>/dev/null || true
			chmod 2775 -- "$_data_dir" 2>/dev/null || chmod 0755 -- "$_data_dir" 2>/dev/null || true
		fi
	fi

	# 3.3 啟動
	local _restart="${INSTALL_RESTART_REL:-restart.sh}"
	if [[ "${SKIP_RESTART:-0}" != "1" ]]; then
		local _rpath="${DEST}/${_restart}"
		if [[ -f "$_rpath" ]]; then
			( cd "$DEST" && bash "$_rpath" ) || {
				printf '%s 執行回傳非 0，請檢查日誌\n' "$_rpath" >&2
			}
		else
			printf '未找到 %s，略過啟動\n' "$_rpath" >&2
		fi
	fi

	printf '完成。專案: %s  安裝版號字串: %s\n' "$DEST" "$VERSION_INI" >&2

	if [[ -n "${SUDO_USER:-}" && -f "$RECORD_FILE" ]]; then
		chown "${SUDO_USER}:${SUDO_USER}" "$RECORD_FILE" 2>/dev/null || true
	fi
}

MAIN "$@"
