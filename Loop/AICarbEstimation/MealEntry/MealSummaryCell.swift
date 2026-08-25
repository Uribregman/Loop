//
//  MealSummaryCell.swift
//  Loop
//
//  Sleek meal card for the history "Meals" view. Shows the meal name + photo (or
//  emoji), the meal time, and a list of components each with their own offset
//  time — so the meal time and the per-component offset times are clearly
//  distinct, e.g.:
//
//     [photo] Pizza night            time: 16:00
//             🍎 apples            offset: 16:00
//             🍕 pizza             offset: 18:00
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI

final class MealSummaryCell: UITableViewCell {

    static let className = "MealSummaryCell"

    private let photoView = UIImageView()
    private let emojiLabel = UILabel()
    private let nameLabel = UILabel()
    private let mealTimeLabel = UILabel()
    private let componentsStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        accessoryType = .disclosureIndicator

        photoView.contentMode = .scaleAspectFill
        photoView.clipsToBounds = true
        photoView.layer.cornerRadius = 20
        photoView.translatesAutoresizingMaskIntoConstraints = false
        photoView.widthAnchor.constraint(equalToConstant: 40).isActive = true
        photoView.heightAnchor.constraint(equalToConstant: 40).isActive = true

        emojiLabel.font = .systemFont(ofSize: 28)
        emojiLabel.textAlignment = .center

        let photoContainer = UIView()
        photoContainer.translatesAutoresizingMaskIntoConstraints = false
        photoContainer.widthAnchor.constraint(equalToConstant: 40).isActive = true
        photoContainer.heightAnchor.constraint(equalToConstant: 40).isActive = true
        [photoView, emojiLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            photoContainer.addSubview($0)
            $0.leadingAnchor.constraint(equalTo: photoContainer.leadingAnchor).isActive = true
            $0.trailingAnchor.constraint(equalTo: photoContainer.trailingAnchor).isActive = true
            $0.topAnchor.constraint(equalTo: photoContainer.topAnchor).isActive = true
            $0.bottomAnchor.constraint(equalTo: photoContainer.bottomAnchor).isActive = true
        }

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.numberOfLines = 1

        mealTimeLabel.font = .preferredFont(forTextStyle: .subheadline)
        mealTimeLabel.textColor = .secondaryLabel
        mealTimeLabel.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [nameLabel, mealTimeLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline

        componentsStack.axis = .vertical
        componentsStack.spacing = 4

        let textStack = UIStackView(arrangedSubviews: [titleRow, componentsStack])
        textStack.axis = .vertical
        textStack.spacing = 6

        let mainStack = UIStackView(arrangedSubviews: [photoContainer, textStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 12
        mainStack.alignment = .top
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
    }

    func configure(entries: [StoredCarbEntry],
                   metadata: MealMetadata?,
                   timeFormatter: DateFormatter,
                   carbFormatter: NumberFormatter) {
        let unit = HKUnit.gram()
        let sorted = entries.sorted { $0.startDate < $1.startDate }

        // Photo or emoji
        if let photo = MealMetadataStore.loadPhoto(metadata?.photoFilename) {
            photoView.image = photo
            photoView.isHidden = false
            emojiLabel.isHidden = true
        } else {
            photoView.isHidden = true
            emojiLabel.isHidden = false
            emojiLabel.text = metadata?.emoji ?? sorted.first?.foodType ?? "🍽️"
        }

        // Name + meal time
        nameLabel.text = metadata?.name.isEmpty == false
            ? metadata!.name
            : NSLocalizedString("Meal", comment: "Default meal name in history")
        let mealTime = metadata?.mealTime ?? sorted.first?.startDate ?? Date()
        mealTimeLabel.text = String(
            format: NSLocalizedString("time: %@", comment: "Meal card meal time"),
            timeFormatter.string(from: mealTime)
        )

        // Component rows: "emoji name    offset: HH:mm"
        componentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for entry in sorted {
            let grams = entry.quantity.doubleValue(for: unit)
            let gramsText = carbFormatter.string(from: grams, unit: unit.unitString) ?? "\(Int(grams)) g"
            let emoji = entry.foodType ?? "•"
            let name = metadata?.name(forStart: entry.startDate)
            let leadingText = name.map { "\(emoji) \($0)  (\(gramsText))" } ?? "\(emoji) \(gramsText)"

            let leading = UILabel()
            leading.font = .preferredFont(forTextStyle: .subheadline)
            leading.text = leadingText

            let trailing = UILabel()
            trailing.font = .preferredFont(forTextStyle: .subheadline)
            trailing.textColor = .secondaryLabel
            trailing.text = String(
                format: NSLocalizedString("offset: %@", comment: "Meal card component offset time"),
                timeFormatter.string(from: entry.startDate)
            )
            trailing.setContentHuggingPriority(.required, for: .horizontal)

            let row = UIStackView(arrangedSubviews: [leading, trailing])
            row.axis = .horizontal
            row.spacing = 8
            componentsStack.addArrangedSubview(row)
        }
    }
}
