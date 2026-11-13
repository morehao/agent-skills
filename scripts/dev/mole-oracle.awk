# 差分 oracle 的比对核心：把「我们的候选清单（TSV）」与「Mole 的 clean-list.txt」
# 按路径 join，分成四类。只用 POSIX awk 特性（macOS 是 BWK awk）。
#
# 输入（按顺序）：
#   1. ours  —— disk-cleanup 的 manifest：code TAB decision TAB kind TAB path TAB reason ...
#   2. mole  —— ~/.config/mole/clean-list.txt：`=== 分区 ===` + `<path>  # <size>`
# 输出：
#   gap_out  —— Mole 会清、我们完全不碰（缺口）
#   con_out  —— 我们标 protected、Mole 会清（口径冲突，安全相关）
#   ext_out  —— 我们计划删、Mole 不碰（我们更激进）
#   stdout   —— KEY<TAB>VALUE 统计行
#
# 「覆盖」= 相等或祖先：对端把那棵树整个删掉，才叫覆盖。
# 只被**后代**覆盖（Mole 删整目录、我们只删里面几个过期文件）记 partial，
# 仍然算差异，但不冒充「完全一致」。

function norm(p) {
    sub(/\/+$/, "", p)
    # macOS 上 /var、/tmp、/etc 是 /private/* 的软链，两边写法可能不同
    if (p ~ /^\/private\/(var|tmp|etc)\//) sub(/^\/private/, "", p)
    return p
}

# 路径与 `  # 说明` 分开：说明里还可能带 `, N items` / `, counted under <path>`。
# 路径本身理论上可以含 `  # `，所以取**最后一次**出现的分隔符。
function split_note(line,   i, last, n) {
    last = 0
    n = length(line) - 3          # "  # " 是 4 个字符
    for (i = 1; i <= n; i++) {
        if (substr(line, i, 4) == "  # ") last = i
    }
    if (last == 0) { NOTE = ""; return line }
    NOTE = substr(line, last + 4)
    return substr(line, 1, last - 1)
}

# "1.20GB, 3 items" → KB；"size unknown" → -1
function note_kb(note,   parts, first, v, u) {
    split(note, parts, ",")
    first = parts[1]
    gsub(/^[ \t]+|[ \t]+$/, "", first)
    if (first !~ /^[0-9]+(\.[0-9]+)?(B|KB|MB|GB)$/) return -1
    match(first, /^[0-9]+(\.[0-9]+)?/)
    v = substr(first, 1, RLENGTH) + 0
    u = substr(first, RLENGTH + 1)
    if (u == "B") return (v < 1 ? 0 : 1)
    if (u == "KB") return int(v + 0.5)
    if (u == "MB") return int(v * 1024 + 0.5)
    if (u == "GB") return int(v * 1048576 + 0.5)
    return -1
}

# cov(m, S, P)：0 不覆盖 / 1 全覆盖（相等或祖先）/ 2 只被后代覆盖（部分）
#   S = 对端的路径集合；P = 「对端在它下面有东西」的前缀集合
function cov(m, S, P,   n, a, i, acc) {
    if (m in S) return 1
    n = split(m, a, "/")
    acc = ""
    for (i = 2; i < n; i++) {
        acc = acc "/" a[i]
        if (acc in S) return 1
    }
    if (m in P) return 2
    return 0
}

BEGIN {
    FS = "\t"; n = 0; acc = ""
    ours_delete = 0; ours_prot = 0; ours_cmd = 0; ours_unv = 0
    mole_total = 0; mole_unknown = 0; n_m = 0; n_del = 0
}

FILENAME == OURS {
    if ($0 ~ /^#/ || NF < 3) next
    code = $1; dec = $2; kind = $3; p = norm($4); reason = $5
    if (kind == "command") { ours_cmd++; next }
    if (dec == "protected") {
        prot[p] = 1; prot_code[p] = code; prot_reason[p] = reason; ours_prot++
    } else if (dec == "delete") {
        del[p] = code; del_list[++n_del] = p; ours_delete++
    } else {
        ours_unv++              # unverified：我们根本不打算删，按「不碰」处理
    }
    # 前缀集合：某个对端路径是 m 的后代时，m 会出现在这里
    n = split(p, a, "/"); acc = ""
    for (i = 2; i < n; i++) {
        acc = acc "/" a[i]
        if (dec == "protected") protpref[acc] = 1
        else delpref[acc] = 1
    }
    next
}

FILENAME == MOLE {
    line = $0
    sub(/\r$/, "", line)
    if (line ~ /^#/ || line ~ /^[ \t]*$/) next
    if (line ~ /^=== /) {
        sec = line
        sub(/^=== /, "", sec); sub(/ ===.*$/, "", sec)
        next
    }
    p = norm(split_note(line))
    if (p == "") next
    kb = note_kb(NOTE)
    mole_total++
    if (kb < 0) mole_unknown++
    mocc[p] = 1
    mlist[++n_m] = p; mkb[p] = kb; msec[p] = (sec == "" ? "-" : sec)
    n = split(p, a, "/"); acc = ""
    for (i = 2; i < n; i++) { acc = acc "/" a[i]; mpref[acc] = 1 }
    next
}

END {
    printf "ours_delete\t%d\n", ours_delete
    printf "ours_protected\t%d\n", ours_prot
    printf "ours_command\t%d\n", ours_cmd
    printf "ours_unverified\t%d\n", ours_unv
    printf "mole_total\t%d\n", mole_total
    printf "mole_unknown\t%d\n", mole_unknown

    gap = 0; gap_partial = 0; con = 0; extra = 0
    for (i = 1; i <= n_m; i++) {
        p = mlist[i]
        c = cov(p, del, delpref)
        if (c == 1) continue                         # 我们整棵也删 → 一致
        cp = cov(p, prot, protpref)
        if (cp > 0) {                                # 我们保护、Mole 会清 → 冲突
            printf "%d\t%s\t%s\t%s\t%d\n", mkb[p], msec[p], p, prot_reason[p], (cp == 2) > con_out
            con++
            continue
        }
        printf "%d\t%s\t%s\t%d\n", mkb[p], msec[p], p, (c == 2) > gap_out
        gap++
        if (c == 2) gap_partial++
    }
    for (i = 1; i <= n_del; i++) {
        p = del_list[i]
        if (cov(p, mocc, mpref) == 1) continue              # Mole 也删这棵（或它的父）→ 不算更激进
        printf "%s\t%s\n", del[p], p > ext_out
        extra++
    }
    printf "gap\t%d\n", gap
    printf "gap_partial\t%d\n", gap_partial
    printf "conflict\t%d\n", con
    printf "extra\t%d\n", extra
}
