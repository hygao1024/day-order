# Agent Note: Shared Content Surface

Status: implemented

## Problem

卡片材质调整后，年份行和设置页仍保留独立实底，导致修改一处不能覆盖全部内容区域。

## Decision

CalendarSurface.swift 中的 CalendarCardBackground 唯一拥有内容背景样式，月视图、年概览和设置页共用 CalendarShell 的常驻背景实例。具体材质与提亮参数继续由[厚材质试用](../../proposed/feature/2026-11-09-thick-calendar-material.md)评估。

年份内容与 AppKit 分组行均不绘制底色，直接露出同一背景；小月历裁剪年份行当前覆盖的区域，沿用现有滚动通知触发重绘。背景复用不取消悬浮年份遮挡日期的责任，独立缩放标题快照不参与此裁剪。

此决定取代[统一设置页面](../feature/2026-10-24-rounded-settings-surface.md)的设置实底例外，以及[弹窗材质](../feature/2026-10-23-popover-material.md)的年份独立底色；其余布局和生命周期决定保留。

## Alternatives considered

- 在每处分别使用相同参数：仍需同步修改，且年份区域二次叠加材质会改变最终颜色。
- 仅删除年份白底：系统分组行仍会绘制默认背景；同时删除两层背景但不裁剪月份，会让滚动日期穿透标题。

## Consequences

内容样式只有一个修改点；年份行新增可见内容裁剪，需保持滚动重绘和快照路径一致。构建、年概览及设置专项检查覆盖当前组合；不同桌面背景下的材质合成与连续手动滚动仍需体验，不以位图快照替代窗口服务器的实际效果。
