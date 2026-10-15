//
//  MFSystemActions.h
//  PullOverMF —— 圆盘「系统动作」（本 fork 新增）
//
//  【0.4.12 用户 log38】用户选定「方案 A」：进程内直调系统私有接口，**零新增 hook**。
//  这些动作的"主人"本来就全在 SpringBoard 里（截图 = SBScreenShotter、翻译 = TranslationUI），
//  而本插件也住在 SpringBoard ⇒ 点一下直接调，延迟为零、开机不受任何影响
//  （符合项目明令："不要在 SpringBoard 里堆 hook"）。
//
//  ★ 设计要点：系统动作用**伪 bundleID**（前缀 `mfsys.`）表示，与真 App 的 bundleID
//    天然不冲突 ⇒ 可以直接混进 ringApps / 编辑器勾选 / 「已添加」排序条，
//    把"圆盘选 App"那一整套成熟机制（含图标贴图、长按移出、顺序调整）原样复用，
//    不需要为动作再写第二套 UI。
//
#import <UIKit/UIKit.h>

/// 系统动作伪 bundleID 的前缀（`mfsys.`）
extern NSString * const MFSystemActionIdPrefix;

/// 该 bundleID 是不是系统动作（圆盘打开 / 图标填充两处都要问这一句）
BOOL MFSystemActionIsActionId(NSString *bundleId);

/// 动作的中文显示名；不是动作时返回 nil
NSString *MFSystemActionDisplayName(NSString *actionId);

/// 动作图标：SF Symbol 渲染成带底圆的位图（圆盘/编辑器/排序条共用同一条贴图路径）。
/// `pointSize` 传渲染尺寸（pt）；不是动作、或取不到符号时返回 nil（调用方会退回首字母占位）。
UIImage *MFSystemActionIcon(NSString *actionId, CGFloat pointSize);

/// 编辑器列表里**置顶**展示的动作条目（@{ @"id": …, @"name": … }）
NSArray<NSDictionary<NSString *, NSString *> *> *MFSystemActionEditorEntries(void);

/// 执行动作。`delay` 秒后才真正执行 —— 截图类动作必须等圆盘收起动画（0.22s）走完，
/// 否则圆盘本身会被截进图里（传 0.35 稳妥）。
/// 全过程 @try 保护：失败只在日志里写明"试了哪些候选、结果如何"，绝不影响插件其它功能。
void MFSystemActionPerform(NSString *actionId, NSTimeInterval delay);
