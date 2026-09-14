#import "IPAAssetCatalogReader.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>

// Runtime-only CoreUI contracts, checked before use; no private framework is linked.
// API references: insidegui/AssetCatalogTinkerer ACS/Private Headers/CoreUI.h and
// showxu/cartools PrivateFrameworks/CoreUI.framework/Versions/A/Headers.
struct IPAAssetToken { uint16_t identifier; uint16_t value; };
@protocol IPAStore <NSObject>
- (instancetype)initWithURL:(NSURL *)url;
- (id)themeStore;
- (id)renditionWithKey:(const struct IPAAssetToken *)key;
- (NSString *)renditionNameForKeyList:(const struct IPAAssetToken *)key;
- (NSString *)nameForAppearanceIdentifier:(unsigned short)identifier;
- (id)localizations;
- (unsigned short)localizationIdentifierForName:(NSString *)name;
@end
@protocol IPAStorage <NSObject>
- (NSArray *)allAssetKeys;
@end
@protocol IPAKey <NSObject>
- (const struct IPAAssetToken *)keyList;
@end
@protocol IPARendition <NSObject>
- (NSString *)name;
- (CGImageRef)unslicedImage;
- (CGPDFDocumentRef)pdfDocument;
- (void *)svgDocument;
- (CGColorRef)cgColor;
- (NSData *)data;
- (double)scale;
- (long long)type;
- (CGSize)unslicedSize;
@end

static NSError *IPAAssetError(NSString *message) {
    return [NSError errorWithDomain:@"ipaverse.asset-catalog" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static id IPAProperty(id object, NSString *name) {
    if (![object respondsToSelector:NSSelectorFromString(name)]) return nil;
    @try { return [object valueForKey:name]; } @catch (NSException *exception) { return nil; }
}
static NSString *IPADigest(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *text = [NSMutableString new];
    for (NSUInteger index = 0; index < sizeof(digest); index++) [text appendFormat:@"%02x", digest[index]];
    return text;
}
static CGContextRef IPACanvas(size_t width, size_t height) CF_RETURNS_RETAINED {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
                                                (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    return context;
}
static NSData *IPAPNG(CGImageRef image) {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    double ratio = MIN(1.0, 512.0 / MAX(width, height));
    CGContextRef context = IPACanvas(MAX(1, (size_t)round(width * ratio)), MAX(1, (size_t)round(height * ratio)));
    if (!context) return nil;
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, CGBitmapContextGetWidth(context), CGBitmapContextGetHeight(context)), image);
    CGImageRef thumbnail = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!thumbnail) return nil;
    NSMutableData *data = [NSMutableData new];
    CGImageDestinationRef output = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    if (!output) { CGImageRelease(thumbnail); return nil; }
    CGImageDestinationAddImage(output, thumbnail, NULL);
    BOOL success = CGImageDestinationFinalize(output);
    CFRelease(output);
    CGImageRelease(thumbnail);
    return success ? data : nil;
}

static NSDictionary *IPAVariant(id<IPAKey> key, id<IPAStore> store, id<IPARendition> rendition) {
    NSMutableDictionary *variant = [NSMutableDictionary new];
    // Exclude themeIdentifier: the compiler can renumber names between catalog builds.
    NSArray *attributes = @[@"themeIdiom", @"themeSubtype", @"themeDisplayGamut", @"themeDirection", @"themeSizeClassHorizontal",
        @"themeSizeClassVertical", @"themeMemoryClass", @"themeGraphicsClass", @"themeDeploymentTarget",
        @"themeState", @"themePresentationState", @"themePreviousState", @"themePreviousValue", @"themeValue",
        @"themeSize", @"themeDimension1", @"themeDimension2", @"themeLayer", @"themeGlyphWeight", @"themeGlyphSize"];
    for (NSString *attribute in attributes) {
        NSNumber *value = IPAProperty(key, attribute);
        if ([value isKindOfClass:NSNumber.class] && value.longLongValue != 0) variant[[attribute substringFromIndex:5]] = value;
    }
    if (![rendition respondsToSelector:@selector(scale)]) {
        @throw [NSException exceptionWithName:@"IPAAssetVariant" reason:@"Rendition scale cannot be resolved" userInfo:nil];
    }
    variant[@"Scale"] = @([rendition scale]);
    NSNumber *appearance = IPAProperty(key, @"themeAppearance");
    if (appearance.unsignedShortValue != 0) {
        NSString *name = [store respondsToSelector:@selector(nameForAppearanceIdentifier:)] ? [store nameForAppearanceIdentifier:appearance.unsignedShortValue] : nil;
        if (!name.length) @throw [NSException exceptionWithName:@"IPAAssetVariant" reason:@"Appearance name cannot be resolved" userInfo:nil];
        variant[@"Appearance"] = name;
    }
    NSNumber *localization = IPAProperty(key, @"themeLocalization");
    if (localization.unsignedShortValue != 0) {
        NSString *resolved = nil;
        if ([store respondsToSelector:@selector(localizations)] && [store respondsToSelector:@selector(localizationIdentifierForName:)]) {
            id localizations = [store localizations];
            NSArray *names = [localizations isKindOfClass:NSDictionary.class] ? [localizations allKeys] :
                [localizations isKindOfClass:NSArray.class] ? localizations : nil;
            for (id name in names) {
                if ([name isKindOfClass:NSString.class] && [store localizationIdentifierForName:name] == localization.unsignedShortValue) { resolved = name; break; }
            }
        }
        if (!resolved) @throw [NSException exceptionWithName:@"IPAAssetVariant" reason:@"Localization name cannot be resolved" userInfo:nil];
        variant[@"Localization"] = resolved;
    }
    return variant;
}

NSArray<NSDictionary<NSString *, id> *> *IPAReadAssetCatalog(NSURL *url, NSUInteger previewBudget, BOOL (^cancelled)(void), NSError **error) {
    @try {
        static void *coreUI;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ coreUI = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_LAZY | RTLD_LOCAL); });
        Class storeClass = NSClassFromString(@"CUIStructuredThemeStore");
        if (!coreUI || !storeClass || ![storeClass instancesRespondToSelector:@selector(initWithURL:)]) {
            if (error) *error = IPAAssetError(@"CoreUI catalog reader is unavailable on this macOS version");
            return nil;
        }
        id<IPAStore> store = [(id<IPAStore>)[storeClass alloc] initWithURL:url];
        if (!store || ![store respondsToSelector:@selector(themeStore)] || ![store respondsToSelector:@selector(renditionWithKey:)]) {
            if (error) *error = IPAAssetError(@"CoreUI could not open the asset catalog");
            return nil;
        }
        id<IPAStorage> storage = [store themeStore];
        if (![storage respondsToSelector:@selector(allAssetKeys)]) {
            if (error) *error = IPAAssetError(@"CoreUI cannot enumerate catalog variants");
            return nil;
        }
        NSArray *keys = [storage allAssetKeys];
        if (![keys isKindOfClass:NSArray.class] || keys.count > 20000) {
            if (error) *error = IPAAssetError(@"Asset catalog inventory unavailable or exceeds 20,000 variants");
            return nil;
        }
        NSMutableArray *records = [NSMutableArray new];
        size_t pixelBudget = 512 * 1024 * 1024;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:90];
        for (id<IPAKey> key in keys) {
            @autoreleasepool {
                if (cancelled()) { if (error) *error = IPAAssetError(@"Asset catalog analysis cancelled"); return nil; }
                if ([deadline timeIntervalSinceNow] <= 0) {
                    if (error) *error = IPAAssetError(@"Asset catalog analysis exceeded 90 seconds");
                    return nil; // Never report the unvisited tail as removals.
                }
                if (![key respondsToSelector:@selector(keyList)]) {
                    if (error) *error = IPAAssetError(@"Unsupported rendition key API");
                    return nil;
                }
                id<IPARendition> rendition = [store renditionWithKey:[key keyList]];
                if (!rendition) {
                    if (error) *error = IPAAssetError(@"CoreUI could not read a catalog rendition");
                    return nil;
                }
                NSString *name = [store respondsToSelector:@selector(renditionNameForKeyList:)] ? [store renditionNameForKeyList:[key keyList]] : nil;
                if (name.length == 0 && [rendition respondsToSelector:@selector(name)]) name = [rendition name];
                if (name.length == 0) {
                    if (error) *error = IPAAssetError(@"A rendition has no stable name; inventory cannot be matched safely");
                    return nil;
                }
                if ([name hasPrefix:@"ZZ"] && [name containsString:@"PackedAsset"]) continue;
                NSMutableDictionary *record = [@{@"Name":name, @"Variant":IPAVariant(key, store, rendition), @"State":@"Unavailable"} mutableCopy];
                NSMutableDictionary *metadata = [NSMutableDictionary new];
                record[@"Metadata"] = metadata;
                [records addObject:record];
                @try {
                    if ([rendition respondsToSelector:@selector(type)]) metadata[@"RenditionType"] = @([rendition type]);
                    NSNumber *templateMode = IPAProperty(rendition, @"templateRenderingMode");
                    if (templateMode) metadata[@"TemplateMode"] = templateMode;
                    CGImageRef ownedImage = NULL;
                    CGImageRef image = NULL;
                    NSString *kind = @"Image";
                    if ([rendition respondsToSelector:@selector(unslicedSize)]) {
                        CGSize size = [rendition unslicedSize];
                        if (!isfinite(size.width) || !isfinite(size.height) || size.width * size.height > 16000000) {
                            record[@"Issue"] = @"Image exceeds 16 million pixels";
                            continue;
                        }
                    }
                    if ([rendition respondsToSelector:@selector(unslicedImage)]) image = [rendition unslicedImage];
                    if (!image && [rendition respondsToSelector:@selector(pdfDocument)]) {
                        CGPDFDocumentRef pdf = [rendition pdfDocument];
                        CGPDFPageRef page = pdf && CGPDFDocumentGetNumberOfPages(pdf) ? CGPDFDocumentGetPage(pdf, 1) : NULL;
                        if (page) {
                            CGRect box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
                            double ratio = MIN(1.0, 2048.0 / MAX(box.size.width, box.size.height));
                            if (box.size.width > 0 && box.size.height > 0 && isfinite(box.size.width) && isfinite(box.size.height) && isfinite(ratio)) {
                                CGContextRef context = IPACanvas(MAX(1, (size_t)ceil(box.size.width * ratio)), MAX(1, (size_t)ceil(box.size.height * ratio)));
                                if (context) {
                                    CGContextScaleCTM(context, ratio, ratio);
                                    CGContextTranslateCTM(context, -box.origin.x, -box.origin.y);
                                    CGContextDrawPDFPage(context, page);
                                    ownedImage = CGBitmapContextCreateImage(context);
                                    CGContextRelease(context);
                                    image = ownedImage;
                                    kind = @"PDF (first page)";
                                }
                            }
                        }
                    }
                    if (!image && [rendition respondsToSelector:@selector(svgDocument)]) {
                        static void *svgLibrary;
                        static dispatch_once_t svgOnce;
                        dispatch_once(&svgOnce, ^{ svgLibrary = dlopen("/System/Library/PrivateFrameworks/CoreSVG.framework/CoreSVG", RTLD_LAZY | RTLD_LOCAL); });
                        CGSize (*canvasSize)(void *) = svgLibrary ? dlsym(svgLibrary, "CGSVGDocumentGetCanvasSize") : NULL;
                        void (*drawSVG)(CGContextRef, void *) = svgLibrary ? dlsym(svgLibrary, "CGContextDrawSVGDocument") : NULL;
                        void *document = canvasSize && drawSVG ? [rendition svgDocument] : NULL;
                        if (document) {
                            CGSize size = canvasSize(document);
                            double ratio = MIN(1.0, 2048.0 / MAX(size.width, size.height));
                            if (size.width > 0 && size.height > 0 && isfinite(size.width) && isfinite(size.height) && isfinite(ratio)) {
                                CGContextRef context = IPACanvas(MAX(1, (size_t)ceil(size.width * ratio)), MAX(1, (size_t)ceil(size.height * ratio)));
                                if (context) {
                                    CGContextScaleCTM(context, ratio, ratio);
                                    drawSVG(context, document);
                                    ownedImage = CGBitmapContextCreateImage(context);
                                    CGContextRelease(context);
                                    image = ownedImage;
                                    kind = @"SVG";
                                    metadata[@"CanvasWidth"] = @(size.width);
                                    metadata[@"CanvasHeight"] = @(size.height);
                                }
                            }
                        }
                    }
                    if (!image && [rendition respondsToSelector:@selector(cgColor)]) {
                        CGColorRef color = [rendition cgColor];
                        if (color) {
                            CGContextRef context = IPACanvas(64, 64);
                            if (context) {
                                CGContextSetFillColorWithColor(context, color);
                                CGContextFillRect(context, CGRectMake(0, 0, 64, 64));
                                ownedImage = CGBitmapContextCreateImage(context);
                                CGContextRelease(context);
                                image = ownedImage;
                                kind = @"Color";
                                NSMutableArray *components = [NSMutableArray new];
                                for (size_t i = 0; i < CGColorGetNumberOfComponents(color); i++) [components addObject:@(CGColorGetComponents(color)[i])];
                                metadata[@"Components"] = components;
                            }
                        }
                    }
                    metadata[@"Kind"] = kind;
                    if (!image) {
                        record[@"Issue"] = @"No renderable image (this rendition may contain vector, data, or layered content)";
                        continue;
                    }
                    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
                    metadata[@"PixelWidth"] = @(width);
                    metadata[@"PixelHeight"] = @(height);
                    if (width == 0 || height == 0 || width > 16000000 / height || width * height * 4 > pixelBudget) {
                        record[@"Issue"] = @"Decoded pixel budget exceeded";
                        if (ownedImage) CGImageRelease(ownedImage);
                        continue;
                    }
                    CGContextRef canvas = IPACanvas(width, height);
                    if (!canvas) {
                        record[@"Issue"] = @"Pixel buffer could not be allocated";
                        if (ownedImage) CGImageRelease(ownedImage);
                        continue;
                    }
                    CGContextSetBlendMode(canvas, kCGBlendModeCopy);
                    CGContextDrawImage(canvas, CGRectMake(0, 0, width, height), image);
                    NSData *pixels = [NSData dataWithBytesNoCopy:CGBitmapContextGetData(canvas) length:width * height * 4 freeWhenDone:NO];
                    record[@"Digest"] = IPADigest(pixels);
                    pixelBudget -= pixels.length;
                    CGContextRelease(canvas);
                    record[@"State"] = @"Complete";
                    if (previewBudget > 0) {
                        NSData *png = IPAPNG(image);
                        if (png && png.length <= previewBudget) {
                            record[@"Preview"] = png;
                            previewBudget -= png.length;
                        } else { record[@"Issue"] = @"Preview encoding/budget limit"; }
                    } else { record[@"Issue"] = @"Preview budget exhausted"; }
                    if (ownedImage) CGImageRelease(ownedImage);
                } @catch (NSException *exception) {
                    record[@"State"] = @"Unavailable";
                    record[@"Issue"] = exception.reason ?: @"CoreUI rendition decoding failed";
                }
            }
        }
        return records;
    } @catch (NSException *exception) {
        if (error) *error = IPAAssetError(exception.reason ?: @"CoreUI catalog decoding failed");
        return nil;
    }
}
