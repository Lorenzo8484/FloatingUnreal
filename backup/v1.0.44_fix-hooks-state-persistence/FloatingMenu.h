#import <UIKit/UIKit.h>
#import "ShaderPage.h"

@interface FloatingMenu : NSObject

@property (nonatomic, strong) UIWindow    *menuWindow;
@property (nonatomic, strong) UIButton    *iconButton;
@property (nonatomic, assign) BOOL         isOpen;

@property (nonatomic, strong) UIView      *debugPanel;
@property (nonatomic, strong) UITextView  *logTextView;
@property (nonatomic, strong) NSMutableArray<NSString *> *logLines;

@property (nonatomic, strong) ShaderPage  *shaderPage;

- (void)show;
- (void)hide;
- (void)addLog:(NSString *)message;
- (void)captureShaderWithName:(NSString *)name source:(NSString *)source error:(NSString *)error;

@end
