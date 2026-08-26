// Non-identifying, derived macro features from the user-labeled repetitions.
const FEATURE_NAMES = Object.freeze([
	"worldBodyVerticalSpan",
	"worldHipVerticalSpan",
	"worldTorsoElevation",
	"worldWristVerticalSpan",
	"dWorldBodyVerticalSpan",
	"dWorldWristVerticalSpan",
]);

const VALUES = Object.freeze([
	[0, 2.1762, 1.6575, 0.5187, 1.0668, -2.6207, -3.2448],
	[329, 1.132, 1.4238, 0.2918, 0.0186, -1.4338, -1.0338],
	[829, 1.013, 1.591, 0.578, 0.3294, 1.0735, 2.5456],
	[1045, 0.6625, 1.0485, 0.386, 0.3215, -2.5179, -1.0373],
	[3313, 1.9479, 1.483, 0.4649, 0.8365, 3.6075, 3.809],
	[7080, 2.6573, 1.6606, 0.9966, 1.8028, 0.0739, 0.1058],
	[27409, 2.2844, 1.6627, 0.6218, 1.2042, -2.5179, -2.9075],
	[27710, 1.1231, 1.4356, 0.3125, 0.0491, -3.8299, -2.3791],
	[30543, 1.8124, 1.445, 0.3674, 0.7057, 2.3179, 2.5522],
	[31076, 2.6513, 1.6729, 0.9783, 1.7464, 0.3157, 0.3687],
]);

export const userLabeledRepFeatureFrames = Object.freeze(
	VALUES.map(([tMs, ...values]) =>
		Object.freeze({
			tMs,
			poseConfidence: 0.9,
			macroLandmarkConfidence: 0.9,
			visibleFraction: 1,
			hasFullWorldLandmarkCoverage: true,
			...Object.fromEntries(
				FEATURE_NAMES.map((name, index) => [name, values[index]]),
			),
		}),
	),
);
