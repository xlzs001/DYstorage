

#import "DPOTheme.h"

static UIColor *DPOColorFromRGB(NSUInteger rgb, CGFloat alpha) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:alpha];
}

UIColor *DPOColorAccent(void) {
    
    return DPOColorFromRGB(0xFE2C55, 1.0);
}

UIColor *DPOColorAccentSoft(void) {
    return [DPOColorAccent() colorWithAlphaComponent:0.12];
}

UIColor *DPOColorBackground(void) {
    return [UIColor systemGroupedBackgroundColor];
}

UIColor *DPOColorCard(void) {
    return [UIColor secondarySystemGroupedBackgroundColor];
}

UIColor *DPOColorSeparator(void) {
    return [UIColor separatorColor];
}

UIColor *DPOColorSecondary(void) {
    return [UIColor secondaryLabelColor];
}

UIColor *DPOColorTertiary(void) {
    return [UIColor tertiaryLabelColor];
}

UIColor *DPOColorFill(void) {
    return [UIColor tertiarySystemFillColor];
}

NSArray<UIColor *> *DPOAvatarColors(NSInteger seed) {
    static NSArray<NSArray<UIColor *> *> *palette = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        palette = @[
            @[ DPOColorFromRGB(0xFF6B81, 1), DPOColorFromRGB(0xFE2C55, 1) ],  
            @[ DPOColorFromRGB(0x6EA8FF, 1), DPOColorFromRGB(0x3D6BFF, 1) ],  
            @[ DPOColorFromRGB(0x7ED6A5, 1), DPOColorFromRGB(0x2BB673, 1) ],  
            @[ DPOColorFromRGB(0xFFC46B, 1), DPOColorFromRGB(0xFF8A3D, 1) ],  
            @[ DPOColorFromRGB(0xB39DFF, 1), DPOColorFromRGB(0x7B5CFF, 1) ],  
            @[ DPOColorFromRGB(0x6FD3E8, 1), DPOColorFromRGB(0x1FA8C9, 1) ],  
        ];
    });
    NSInteger index = labs(seed) % (NSInteger)palette.count;
    return palette[(NSUInteger)index];
}

UIFont *DPOFont(CGFloat size, UIFontWeight weight) {
    UIFont *font = [UIFont systemFontOfSize:size weight:weight];
    if (font != nil) return font;
    return [UIFont systemFontOfSize:size];
}

UIFont *DPOFontMonospaced(CGFloat size, UIFontWeight weight) {
    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:size weight:weight];
    return font ?: DPOFont(size, weight);
}
