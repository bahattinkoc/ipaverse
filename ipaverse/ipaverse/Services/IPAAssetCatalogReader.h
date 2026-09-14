#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Read rendition metadata and bounded previews. Does not load or execute the source app.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> * _Nullable IPAReadAssetCatalog(
    NSURL *url, NSUInteger previewBudget, BOOL (^cancelled)(void), NSError * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
