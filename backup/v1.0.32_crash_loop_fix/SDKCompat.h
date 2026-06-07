#pragma once
#import <Metal/Metal.h>
@protocol MTLFunction_iOS14 <MTLFunction>
@property (readonly) id<MTLLibrary> library;
@end
#ifndef MTLNewFunctionCompletionHandlerDefined
#define MTLNewFunctionCompletionHandlerDefined
typedef void (^MTLNewFunctionCompletionHandler)(id<MTLFunction> _Nullable, NSError * _Nullable);
#endif
