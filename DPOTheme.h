

#import "DPOCommon.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT UIColor *DPOColorAccent(void);
FOUNDATION_EXPORT UIColor *DPOColorAccentSoft(void);
FOUNDATION_EXPORT UIColor *DPOColorBackground(void);
FOUNDATION_EXPORT UIColor *DPOColorCard(void);
FOUNDATION_EXPORT UIColor *DPOColorSeparator(void);
FOUNDATION_EXPORT UIColor *DPOColorSecondary(void);
FOUNDATION_EXPORT UIColor *DPOColorTertiary(void);
FOUNDATION_EXPORT UIColor *DPOColorFill(void);

FOUNDATION_EXPORT NSArray<UIColor *> *DPOAvatarColors(NSInteger seed);

FOUNDATION_EXPORT UIFont *DPOFont(CGFloat size, UIFontWeight weight);
FOUNDATION_EXPORT UIFont *DPOFontMonospaced(CGFloat size, UIFontWeight weight);

NS_ASSUME_NONNULL_END
