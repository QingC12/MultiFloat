#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
setter_check.py —— PullOverMF / MultiFloat 交付前自检（第 4 件套）

用途：拦住一类会**当场杀死 SpringBoard**、但编译器（-w）不会提醒的 ObjC 写法：

    类里声明了  @property (nonatomic, weak) UIButton *selectedButton;
    又手写了一个同名方法  - (void)setSelectedButton:(UIButton *)button { ... self.selectedButton = button; ... }

属性赋值 `self.selectedButton = x` 会被编译成
    objc_msgSend(self, @selector(setSelectedButton:), x)
也就是**调用它自己** → 无限递归 → 栈溢出 → SIGSEGV。
SIGSEGV 抓不住（不是 NSException）、不进安全模式，宿主进程（SpringBoard）直接死
→ 用户看到"黑屏 + 自动注销"。

这就是 PullOverMF 0.1.6 / 0.1.7 / 0.1.8 / 0.1.9 连续四版"右边缘一滑就注销"的真凶：
每版 `MFRingPicker.m` 都同时有 `selectedButton` 属性和同名的 `setSelectedButton:`。

检查规则：
  1) 手写方法 `- (…)setXxx:` 的 Xxx 与该文件里某条 @property 同名（首字母小写后相同）
     ⇒ 报 ERROR。
  2) 该手写 setter 体内又出现 `self.xxx =`（同一属性）⇒ 报 RECURSION（必然死递归）。
  3) 附带提醒：手写 setter 体内写 `_ivar` 是安全的写法。

用法：
    python setter_check.py <文件或目录> [...]
退出码：0 = 干净；1 = 发现问题。
"""

import os
import re
import sys

# @property (attrs) Type name;   —— 允许指针/泛型/空格
PROP_RE = re.compile(
    r'@property\s*\([^)]*\)\s*'
    r'(?:[A-Za-z_][A-Za-z0-9_]*\s*<[^>]*>\s*\**\s*'   # 泛型类型（可能带 *）
    r'|[A-Za-z_][A-Za-z0-9_]*\s*\**\s*)'              # 普通类型（可能带 *）
    r'([A-Za-z_][A-Za-z0-9_]*)'                       # 属性名
    r'\s*;'
)

# 手写 setter 定义：- (void)setFoo:(Type)v  {   （只认定义，即后面跟 {；声明以 ; 结尾）
SETTER_DEF_RE = re.compile(r'^-\s*\(\s*void\s*\)\s*set([A-Z][A-Za-z0-9_]*)\s*:.*\{\s*$')

SRC_EXT = ('.m', '.mm')


def lower_first(name: str) -> str:
    return name[:1].lower() + name[1:] if name else name


def scan_file(path: str):
    problems = []
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            lines = handle.read().split('\n')
    except OSError as exc:
        return [('IO', 0, None, '无法读取：%s' % exc)]

    props = {}
    for index, line in enumerate(lines, start=1):
        for match in PROP_RE.finditer(line):
            props.setdefault(match.group(1), index)

    if not props:
        return problems

    for index, line in enumerate(lines, start=1):
        stripped = line.strip()
        match = SETTER_DEF_RE.match(stripped)
        if not match:
            continue
        suffix = match.group(1)
        prop = lower_first(suffix)
        if prop not in props:
            continue
        # 找到方法体（到下一个顶层 '}' 结束，简单按缩进括号配平）
        depth = 1
        body = []
        for follow in lines[index:]:
            depth += follow.count('{') - follow.count('}')
            body.append(follow)
            if depth <= 0:
                break
        body_text = '\n'.join(body)
        # 属性自赋值（递归）；ivar 自赋值是安全的
        self_assign = re.search(r'self\.%s\s*=' % re.escape(prop), body_text) is not None
        ivar_assign = re.search(r'(?<![\w.])_%s\s*=' % re.escape(prop), body_text) is not None
        problems.append((
            'RECURSION' if self_assign else 'SHADOW_SETTER',
            index,
            prop,
            '手写 -set%s: 与属性 %s（第 %d 行声明）撞名；体内 %s'
            % (suffix, prop, props[prop],
               '出现 `self.%s =` ⇒ **必然无限递归 / 栈溢出**（SIGSEGV，进程当场死）'
               % prop if self_assign
               else '未出现 self.%s =（暂时安全），但仍建议改名以免日后误写' % prop),
        ))
        if ivar_assign:
            problems[-1] = (problems[-1][0], problems[-1][1], problems[-1][2],
                            problems[-1][3] + '（检测到 `_%s =` 写法，这部分是安全的）' % prop)
    return problems


def iter_sources(targets):
    for target in targets:
        if os.path.isdir(target):
            for root, _dirs, files in os.walk(target):
                for name in sorted(files):
                    if name.endswith(SRC_EXT):
                        yield os.path.join(root, name)
        elif os.path.isfile(target):
            yield target


def main(argv):
    targets = argv[1:]
    if not targets:
        print(__doc__)
        return 2
    total = 0
    fatal = 0
    for path in iter_sources(targets):
        for kind, line, prop, message in scan_file(path):
            total += 1
            if kind == 'RECURSION':
                fatal += 1
            print('[%s] %s:%d  property=%s\n    %s' % (kind, path, line, prop, message))
    if total == 0:
        print('setter_check: OK —— 未发现「手写 setter 与同名属性撞车」')
        return 0
    print('setter_check: 共 %d 处问题，其中致命 %d 处' % (total, fatal))
    return 1 if fatal else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
