#import "POSceneSession.h"

// 【M1 / S1】纯状态容器：属性全部自动合成，无业务逻辑。
// 业务逻辑仍由 ContextHostManager 持有，本类只负责「让状态可以每窗一份」。
@implementation POSceneSession
@end
