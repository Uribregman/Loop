//
//  SleepWindowProvider.swift
//  Loop
//
//  ⚠️ CURRENTLY UNUSED. Nothing calls this.
//
//  The basal review deliberately uses a FIXED 00:00–07:00 window now (see
//  `TherapyInsights.nightStartHour`): sleep-derived windows were a different
//  length every night, which made the reported hours meaningless and put the
//  whole review behind a Health permission. Kept because it is read-only, self-
//  contained and correct if a future feature wants real sleep times — not
//  because anything depends on it.
//
//  Reads sleep periods from HealthKit so a caller can look at the hours
//  the user was ACTUALLY asleep rather than a fixed clock window.
//
//  Read-only, and entirely optional: if permission is refused or there is no
//  sleep data, every caller falls back to a fixed overnight window. Nothing here
//  gates a feature behind a Health permission.
//
//  Why bother: a fixed midnight–07:00 window silently mixes "awake and eating at
//  01:00" into a basal assessment. Sleep is the cleanest fasting period most
//  people have, and using the real one makes the evidence better rather than
//  merely more plentiful.
//

import Foundation
import HealthKit

final class SleepWindowProvider {
    static let shared = SleepWindowProvider()

    private let store = HKHealthStore()

    private var sleepType: HKCategoryType? {
        HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)
    }

    /// Ask for read access to sleep. Safe to call repeatedly; iOS shows the
    /// prompt once. Never throws into the caller — a refusal is a normal outcome
    /// here, not an error.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable(), let sleepType else { return }
        try? await store.requestAuthorization(toShare: [], read: [sleepType])
    }

    /// Intervals the user was asleep between `start` and `end`.
    ///
    /// Returns an empty array when unavailable, unauthorised, or simply not
    /// recorded — deliberately indistinguishable, because HealthKit does not
    /// reveal read-permission denials and pretending otherwise would be a lie.
    func asleepIntervals(from start: Date, to end: Date) async -> [DateInterval] {
        guard HKHealthStore.isHealthDataAvailable(), let sleepType else { return [] }

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                         ascending: true)]) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }

        // "In bed" is not "asleep" — someone can lie awake eating crisps. Only
        // the actual asleep states count.
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]

        let asleep = samples
            .filter { asleepValues.contains($0.value) }
            .map { DateInterval(start: $0.startDate, end: $0.endDate) }
            .sorted { $0.start < $1.start }

        return merge(asleep)
    }

    /// Merge touching or overlapping intervals — sleep stages arrive as many
    /// short adjacent samples, and treating each as its own "night" would make
    /// every window far too short to assess anything.
    private func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        guard !intervals.isEmpty else { return [] }
        var merged: [DateInterval] = [intervals[0]]
        for interval in intervals.dropFirst() {
            let last = merged[merged.count - 1]
            // A gap under 20 minutes is a brief waking, not the end of the night.
            if interval.start.timeIntervalSince(last.end) <= 20 * 60 {
                merged[merged.count - 1] = DateInterval(start: last.start,
                                                        end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        // Anything under 3 hours is a nap, and a nap is not a basal test.
        return merged.filter { $0.duration >= 3 * 3600 }
    }
}
