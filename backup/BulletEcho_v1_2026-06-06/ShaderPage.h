#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, FragPatchColor) {
    FragPatchNone  = 0,
    FragPatchRed   = 1,
    FragPatchGreen = 2,
    FragPatchBlue  = 3,
};

@interface ShaderEntry : NSObject
@property (nonatomic, strong) NSString       *name;
@property (nonatomic, strong) NSString       *stableKey;
@property (nonatomic, strong) NSString       *customName;
@property (nonatomic, strong) NSString       *displayName;
@property (nonatomic, strong) NSString       *subMembersText;
@property (nonatomic, strong) NSString       *vglobalsName;
@property (nonatomic, strong) NSString       *vglobalsText;
@property (nonatomic, strong) NSString       *source;
@property (nonatomic, strong) NSString       *errorInfo;
@property (nonatomic, strong) NSDate         *capturedAt;
@property (nonatomic, assign) NSUInteger      sourceHash;
@property (nonatomic, assign) BOOL            hasVertexFunction;
@property (nonatomic, assign) BOOL            hasFragmentFunction;
@property (nonatomic, assign) BOOL            isDivider;
@property (nonatomic, assign) BOOL            isSaved;
@property (nonatomic, assign) NSInteger       fragIndex;
@property (nonatomic, assign) NSInteger       vertIndex;
@property (nonatomic, assign) FragPatchColor  patchFragColor;
@property (nonatomic, assign) BOOL            patchFlash;
@property (nonatomic, assign) BOOL            patchVertex;
@property (nonatomic, assign) BOOL            patchShadeOverride;
@property (nonatomic, assign) float           patchShadeR;
@property (nonatomic, assign) float           patchShadeG;
@property (nonatomic, assign) float           patchShadeB;
@end

@interface ShaderPage : UIView

@property (nonatomic, strong) NSMutableArray<ShaderEntry *> *shaders;
@property (nonatomic, strong) NSMutableArray<ShaderEntry *> *filteredShaders;
@property (nonatomic, strong) UITableView   *shaderList;
@property (nonatomic, strong) UITextField   *searchField;
@property (nonatomic, strong) UITextField   *smartField;
@property (nonatomic, strong) UITextField   *jumpField;
@property (nonatomic, strong) UIView        *detailView;
@property (nonatomic, strong) UITextView    *sourceTextView;
@property (nonatomic, strong) UILabel       *errorLabel;
@property (nonatomic, strong) UIButton      *srcCopyBtn;
@property (nonatomic, strong) UIButton      *backBtn;

@property (nonatomic, assign) BOOL masterSwitchEnabled;
@property (nonatomic, copy) void (^patchChangedHandler)(ShaderEntry *entry);
@property (nonatomic, copy) void (^hookSwitchChangedHandler)(BOOL enabled);
@property (nonatomic, copy) void (^logTappedHandler)(void);
@property (nonatomic, copy) void (^headerTappedHandler)(void);

- (ShaderEntry *)entryForSourceHash:(NSUInteger)hash;
- (void)addShaderWithName:(NSString *)name source:(NSString *)source error:(NSString *)error;
- (void)clearShaders;
- (void)refresh;

@end
