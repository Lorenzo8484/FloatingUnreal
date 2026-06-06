#import <UIKit/UIKit.h>
typedef NS_ENUM(NSInteger, FragPatchColor) { FragPatchNone=0, FragPatchRed=1, FragPatchGreen=2, FragPatchBlue=3 };
@interface ShaderEntry : NSObject
@property (nonatomic, strong) NSString *name, *stableKey, *customName, *displayName, *subMembersText, *vglobalsName, *vglobalsText, *source, *errorInfo;
@property (nonatomic, strong) NSDate *capturedAt;
@property (nonatomic, assign) NSUInteger sourceHash;
@property (nonatomic, assign) BOOL hasVertexFunction, hasFragmentFunction, isDivider, isSaved, patchFlash, patchVertex, patchShadeOverride;
@property (nonatomic, assign) NSInteger fragIndex, vertIndex;
@property (nonatomic, assign) FragPatchColor patchFragColor;
@property (nonatomic, assign) float patchShadeR, patchShadeG, patchShadeB;
@end
@interface ShaderPage : UIView
@property (nonatomic, strong) NSMutableArray<ShaderEntry *> *shaders, *filteredShaders;
@property (nonatomic, strong) UITableView *shaderList;
@property (nonatomic, strong) UITextField *searchField, *smartField, *jumpField;
@property (nonatomic, strong) UIView *detailView;
@property (nonatomic, strong) UITextView *sourceTextView;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) UIButton *srcCopyBtn, *backBtn;
@property (nonatomic, assign) BOOL masterSwitchEnabled;
@property (nonatomic, copy) void (^patchChangedHandler)(ShaderEntry *entry);
@property (nonatomic, copy) void (^hookSwitchChangedHandler)(BOOL enabled);
@property (nonatomic, copy) void (^logTappedHandler)(void);
@property (nonatomic, copy) void (^headerTappedHandler)(void);
- (ShaderEntry *)entryForSourceHash:(NSUInteger)hash;
- (void)addShaderWithName:(NSString *)name source:(NSString *)source error:(NSString *)error;
- (void)clearShaders;
- (void)refresh;
- (void)applyHookSwitchState:(BOOL)enabled;
- (void)resetActivePatchesOnly;
@end
