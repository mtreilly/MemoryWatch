import Foundation

struct LeakHeuristics {
    struct Evaluation {
        let slopeMBPerHour: Double
        let intercept: Double
        let rSquared: Double
        let medianAbsoluteDeviation: Double
        let positiveIntervalRatio: Double
        let growthMB: Double
        let durationHours: Double
        let sampleCount: Int
    }

    static func evaluate(samples: ArraySlice<ProcessSnapshot>) -> Evaluation? {
        guard samples.count >= 5 else { return nil }

        let baseTime = samples.first!.timestamp.timeIntervalSince1970
        var xs: [Double] = []
        var ys: [Double] = []
        xs.reserveCapacity(samples.count)
        ys.reserveCapacity(samples.count)

        for sample in samples {
            let hours = (sample.timestamp.timeIntervalSince1970 - baseTime) / 3600.0
            xs.append(hours)
            ys.append(sample.memoryMB)
        }

        guard let regression = linearRegression(x: xs, y: ys) else { return nil }

        let slope = regression.slope
        let intercept = regression.intercept
        let rSquared = regression.rSquared
        let growth = max(0, (xs.last ?? 0) * slope + intercept - (xs.first ?? 0) * slope - intercept)

        let residuals = residualSeries(x: xs, y: ys, slope: slope, intercept: intercept)
        let mad = medianAbsoluteDeviation(residuals)

        let positiveRatio = positiveIntervalShare(samples: Array(samples))
        let durationHours = xs.last ?? 0

        return Evaluation(
            slopeMBPerHour: slope,
            intercept: intercept,
            rSquared: rSquared,
            medianAbsoluteDeviation: mad,
            positiveIntervalRatio: positiveRatio,
            growthMB: growth,
            durationHours: durationHours,
            sampleCount: samples.count
        )
    }

    static func suspicionLevel(for evaluation: Evaluation) -> LeakSuspect.SuspicionLevel {
        let slope = evaluation.slopeMBPerHour
        let growth = evaluation.growthMB
        let noiseRatio = evaluation.medianAbsoluteDeviation / max(1, abs(slope))
        let positiveRatio = evaluation.positiveIntervalRatio

        if slope >= 80 && growth >= 400 && evaluation.rSquared >= 0.70 && noiseRatio < 0.40 {
            return .critical
        }

        if slope >= 45 && growth >= 250 && evaluation.rSquared >= 0.55 && noiseRatio < 0.55 {
            return .high
        }

        if slope >= 25 && growth >= 120 && positiveRatio >= 0.68 {
            return .medium
        }

        if slope >= 12 && growth >= 80 && positiveRatio >= 0.60 {
            return .low
        }

        return .low
    }

    // MARK: - Helpers

    private static func linearRegression(x: [Double], y: [Double]) -> (slope: Double, intercept: Double, rSquared: Double)? {
        let n = Double(x.count)
        guard n >= 2 else { return nil }

        let sumX = x.reduce(0, +)
        let sumY = y.reduce(0, +)
        let meanX = sumX / n
        let meanY = sumY / n

        var numerator: Double = 0
        var denominator: Double = 0
        var totalVariance: Double = 0

        for i in 0..<x.count {
            let dx = x[i] - meanX
            numerator += dx * (y[i] - meanY)
            denominator += dx * dx
            totalVariance += (y[i] - meanY) * (y[i] - meanY)
        }

        guard denominator != 0 else { return nil }

        let slope = numerator / denominator
        let intercept = meanY - slope * meanX

        // Calculate R^2
        var residualVariance: Double = 0
        for i in 0..<x.count {
            let predicted = slope * x[i] + intercept
            let residual = y[i] - predicted
            residualVariance += residual * residual
        }

        let rSquared: Double
        if totalVariance == 0 {
            rSquared = 1.0
        } else {
            rSquared = max(0, 1 - (residualVariance / totalVariance))
        }

        return (slope, intercept, rSquared)
    }

    private static func residualSeries(x: [Double], y: [Double], slope: Double, intercept: Double) -> [Double] {
        guard !x.isEmpty else { return [] }
        var residuals: [Double] = []
        residuals.reserveCapacity(x.count)
        for i in 0..<x.count {
            let predicted = slope * x[i] + intercept
            residuals.append(y[i] - predicted)
        }
        return residuals
    }

    private static func medianAbsoluteDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let medianValue = median(values)
        let deviations = values.map { abs($0 - medianValue) }
        return median(deviations)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        } else {
            return sorted[middle]
        }
    }

    private static func positiveIntervalShare(samples: [ProcessSnapshot]) -> Double {
        guard samples.count >= 2 else { return 0 }
        var positive = 0
        var total = 0
        for pair in zip(samples.dropLast(), samples.dropFirst()) {
            total += 1
            if pair.1.memoryMB - pair.0.memoryMB > 0 {
                positive += 1
            }
        }
        return total > 0 ? Double(positive) / Double(total) : 0
    }
}
