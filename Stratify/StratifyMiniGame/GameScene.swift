//
//  GameScene.swift
//  StratifyMiniGame
//
//  Created by Andrew Benson on 10/27/25.
//

import SpriteKit
import AppKit

class GameScene: SKScene, SKPhysicsContactDelegate {

    // Game elements
    private var wheel: SKNode?
    private var wheelSegments: [(color: NSColor, symbol: String)] = []
    private var currentBall: SKShapeNode?
    private var leftHandLabel: SKLabelNode?
    private var rightHandLabel: SKLabelNode?
    private var scoreLabel: SKLabelNode?
    private var highScoreLabel: SKLabelNode?

    // Game state
    private var currentRotation: CGFloat = 0
    private var score: Int = 0 {
        didSet {
            scoreLabel?.text = "SCORE: \(score)"
            if score > highScore {
                highScore = score
                UserDefaults.standard.set(highScore, forKey: "StratifyHighScore")
                highScoreLabel?.text = "HIGH: \(highScore)"
            }
        }
    }
    private var highScore: Int = 0
    private var isGameActive = false
    private var isGameEnding = false
    private var isBallFallingToHands = false
    private var hasCaughtBall = false

    // Physics categories
    private let ballCategory: UInt32 = 0x1 << 0
    private let wheelCategory: UInt32 = 0x1 << 1

    // Color and symbol configuration
    private let colorSymbols: [(color: NSColor, symbol: String)] = [
        (.orange, "⭐"),   // Star
        (.blue, "●"),     // Circle
        (.red, "▲"),      // Triangle
        (.green, "■"),    // Square
        (.yellow, "✕")    // Cross
    ]

    override func didMove(to view: SKView) {
        backgroundColor = .black
        physicsWorld.contactDelegate = self
        physicsWorld.gravity = CGVector(dx: 0, dy: -9.8)

        highScore = UserDefaults.standard.integer(forKey: "StratifyHighScore")

        setupWheel()
        setupScoreLabels()
        setupHands()
        spawnBall()
    }

    private func setupWheel() {
        let wheelNode = SKNode()
        wheelNode.position = CGPoint(x: size.width / 2, y: 100)
        addChild(wheelNode)
        wheel = wheelNode

        let radius: CGFloat = 120
        let segmentAngle = CGFloat(2 * Double.pi / 5)

        for i in 0..<5 {
            let segment = createWheelSegment(
                radius: radius,
                startAngle: CGFloat(i) * segmentAngle,
                endAngle: CGFloat(i + 1) * segmentAngle,
                color: colorSymbols[i].color,
                symbol: colorSymbols[i].symbol
            )
            wheelNode.addChild(segment)
        }

        let physicsBody = SKPhysicsBody(circleOfRadius: radius)
        physicsBody.isDynamic = false
        physicsBody.categoryBitMask = wheelCategory
        physicsBody.contactTestBitMask = ballCategory
        wheelNode.physicsBody = physicsBody
    }

    private func createWheelSegment(radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, color: NSColor, symbol: String) -> SKNode {
        let segmentNode = SKNode()

        let path = CGMutablePath()
        path.move(to: .zero)
        path.addArc(center: .zero, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.closeSubpath()

        let segment = SKShapeNode(path: path)
        segment.fillColor = color
        segment.strokeColor = .white
        segment.lineWidth = 2
        segmentNode.addChild(segment)

        let midAngle = (startAngle + endAngle) / 2
        let symbolRadius = radius * 0.7
        let symbolX = cos(midAngle) * symbolRadius
        let symbolY = sin(midAngle) * symbolRadius

        let backgroundCircle = SKShapeNode(circleOfRadius: 18)
        backgroundCircle.fillColor = .black
        backgroundCircle.strokeColor = .white
        backgroundCircle.lineWidth = 1
        backgroundCircle.position = CGPoint(x: symbolX, y: symbolY)
        segmentNode.addChild(backgroundCircle)

        let symbolLabel = SKLabelNode(text: symbol)
        symbolLabel.fontSize = 30
        symbolLabel.fontColor = .white
        symbolLabel.position = CGPoint(x: symbolX, y: symbolY - 10)
        symbolLabel.verticalAlignmentMode = .center
        segmentNode.addChild(symbolLabel)

        return segmentNode
    }

    private func setupScoreLabels() {
        scoreLabel = SKLabelNode(fontNamed: "Courier-Bold")
        scoreLabel?.text = "SCORE: 0"
        scoreLabel?.fontSize = 24
        scoreLabel?.fontColor = .white
        scoreLabel?.position = CGPoint(x: 100, y: size.height - 40)
        scoreLabel?.horizontalAlignmentMode = .left
        if let scoreLabel = scoreLabel {
            addChild(scoreLabel)
        }

        highScoreLabel = SKLabelNode(fontNamed: "Courier-Bold")
        highScoreLabel?.text = "HIGH: \(highScore)"
        highScoreLabel?.fontSize = 24
        highScoreLabel?.fontColor = .gray
        highScoreLabel?.position = CGPoint(x: size.width - 100, y: size.height - 40)
        highScoreLabel?.horizontalAlignmentMode = .right
        if let highScoreLabel = highScoreLabel {
            addChild(highScoreLabel)
        }
    }

    private func setupHands() {
        leftHandLabel = SKLabelNode(text: "🫲")
        leftHandLabel?.fontSize = 60
        leftHandLabel?.position = CGPoint(x: size.width / 2 - 30, y: size.height - 150)
        leftHandLabel?.xScale = -1
        if let leftHandLabel = leftHandLabel {
            addChild(leftHandLabel)
        }

        rightHandLabel = SKLabelNode(text: "🫱")
        rightHandLabel?.fontSize = 60
        rightHandLabel?.position = CGPoint(x: size.width / 2 + 30, y: size.height - 150)
        rightHandLabel?.xScale = -1
        if let rightHandLabel = rightHandLabel {
            addChild(rightHandLabel)
        }
    }

    private func spawnBall() {
        currentBall?.removeFromParent()

        isGameEnding = false
        let randomColor = colorSymbols.randomElement() ?? colorSymbols[0]
        let ball = SKShapeNode(circleOfRadius: 20)
        ball.fillColor = randomColor.color
        ball.strokeColor = .white
        ball.lineWidth = 2
        ball.position = CGPoint(x: size.width / 2, y: size.height - 50)
        ball.name = "\(randomColor.color)"

        let backgroundCircle = SKShapeNode(circleOfRadius: 12)
        backgroundCircle.fillColor = .black
        backgroundCircle.strokeColor = .clear
        backgroundCircle.position = .zero
        ball.addChild(backgroundCircle)

        let symbolLabel = SKLabelNode(text: randomColor.symbol)
        symbolLabel.fontSize = 24
        symbolLabel.fontColor = .white
        symbolLabel.position = CGPoint(x: 0, y: -8)
        symbolLabel.verticalAlignmentMode = .center
        ball.addChild(symbolLabel)

        let physicsBody = SKPhysicsBody(circleOfRadius: 20)
        physicsBody.categoryBitMask = ballCategory
        physicsBody.contactTestBitMask = wheelCategory
        physicsBody.collisionBitMask = wheelCategory
        physicsBody.restitution = 0.3
        physicsBody.friction = 0.5
        physicsBody.affectedByGravity = true
        ball.physicsBody = physicsBody

        currentBall = ball
        addChild(ball)

        isGameActive = false
        isBallFallingToHands = true
        hasCaughtBall = false

        resetHands()
    }

    private func dropBall() {
        guard let ball = currentBall else { return }

        let pullApartDistance: CGFloat = 60
        let pullDuration: TimeInterval = 0.2

        let moveLeft = SKAction.moveBy(x: -pullApartDistance, y: 0, duration: pullDuration)
        let moveRight = SKAction.moveBy(x: pullApartDistance, y: 0, duration: pullDuration)
        let flipToNormal = SKAction.scaleX(to: 1.0, duration: pullDuration)

        let leftActions = SKAction.group([moveLeft, flipToNormal])
        let rightActions = SKAction.group([moveRight, flipToNormal])

        leftHandLabel?.run(leftActions)
        rightHandLabel?.run(rightActions)

        let wait = SKAction.wait(forDuration: pullDuration)
        let enableGravity = SKAction.run { [weak self] in
            ball.physicsBody?.affectedByGravity = true
            self?.isGameActive = true
            NSSound.beep()
        }
        run(SKAction.sequence([wait, enableGravity]))
    }

    private func resetHands() {
        let centerY = size.height - 150
        let leftX = size.width / 2 - 30
        let rightX = size.width / 2 + 30

        let moveToCenter = SKAction.move(to: CGPoint(x: leftX, y: centerY), duration: 0.3)
        let flipToHolding = SKAction.scaleX(to: -1.0, duration: 0.3)
        let leftActions = SKAction.group([moveToCenter, flipToHolding])
        leftHandLabel?.run(leftActions)

        let moveRightToCenter = SKAction.move(to: CGPoint(x: rightX, y: centerY), duration: 0.3)
        let rightActions = SKAction.group([moveRightToCenter, flipToHolding])
        rightHandLabel?.run(rightActions)
    }

    private func rotateWheel(byDegrees degrees: CGFloat) {
        let radians = degrees * CGFloat.pi / 180
        currentRotation += radians
        let rotateAction = SKAction.rotate(byAngle: radians, duration: 0.1)
        wheel?.run(rotateAction)
    }

    override func keyDown(with event: NSEvent) {
        let leftArrow: UInt16 = 123
        let rightArrow: UInt16 = 124
        let aKey: UInt16 = 0
        let dKey: UInt16 = 2

        switch event.keyCode {
        case leftArrow, aKey:
            rotateWheel(byDegrees: -15)
        case rightArrow, dKey:
            rotateWheel(byDegrees: 15)
        default:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = event.location(in: self)
        if location.x < size.width / 2 {
            rotateWheel(byDegrees: -15)
        } else {
            rotateWheel(byDegrees: 15)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        rotateWheel(byDegrees: 15)
    }

    func didBegin(_ contact: SKPhysicsContact) {
        guard isGameActive else { return }

        let bodyA = contact.bodyA
        let bodyB = contact.bodyB

        let ballBody: SKPhysicsBody?
        if bodyA.categoryBitMask == ballCategory {
            ballBody = bodyA
        } else if bodyB.categoryBitMask == ballCategory {
            ballBody = bodyB
        } else {
            return
        }

        guard let ball = ballBody?.node as? SKShapeNode else { return }
        guard let ballColorString = ball.name else { return }
        guard let wheel = wheel else { return }

        let contactPoint = contact.contactPoint
        let wheelPosition = wheel.position
        let relativePoint = CGPoint(x: contactPoint.x - wheelPosition.x, y: contactPoint.y - wheelPosition.y)

        var angle = atan2(relativePoint.y, relativePoint.x)
        angle -= currentRotation
        while angle < 0 {
            angle += 2 * CGFloat.pi
        }
        while angle >= 2 * CGFloat.pi {
            angle -= 2 * CGFloat.pi
        }

        let segmentAngle = 2 * CGFloat.pi / 5
        let segmentIndex = Int(angle / segmentAngle) % 5

        let expectedColor = colorSymbols[segmentIndex].color

        if ballColorString.contains(expectedColor.description) || colorsMatch(ballColorString, expectedColor) {
            score += 1
            isGameActive = false
            spawnBall()
        } else {
            isGameActive = false
            isGameEnding = true

            let contactNormal = CGVector(dx: relativePoint.x, dy: relativePoint.y)
            let magnitude = sqrt(contactNormal.dx * contactNormal.dx + contactNormal.dy * contactNormal.dy)
            let normalizedNormal = CGVector(dx: contactNormal.dx / magnitude, dy: contactNormal.dy / magnitude)

            let bounceImpulse = CGVector(dx: normalizedNormal.dx * 300, dy: normalizedNormal.dy * 300)
            ball.physicsBody?.applyImpulse(bounceImpulse)
        }
    }

    private func colorsMatch(_ colorString: String, _ color: NSColor) -> Bool {
        switch color {
        case .orange:
            return colorString.contains("orange") || colorString.contains("1 0.5 0")
        case .blue:
            return colorString.contains("blue") || colorString.contains("0 0 1")
        case .red:
            return colorString.contains("red") || colorString.contains("1 0 0")
        case .green:
            return colorString.contains("green") || colorString.contains("0 1 0") || colorString.contains("0 0.5 0")
        case .yellow:
            return colorString.contains("yellow") || colorString.contains("1 1 0")
        default:
            return false
        }
    }

    private func gameOver() {
        isGameActive = false
        currentBall?.physicsBody?.affectedByGravity = false
        currentBall?.physicsBody?.velocity = .zero

        let gameOverLabel = SKLabelNode(fontNamed: "PT Mono")
        gameOverLabel.text = "GAME OVER"
        gameOverLabel.fontSize = 48
        gameOverLabel.fontColor = .red
        gameOverLabel.position = CGPoint(x: size.width / 2, y: size.height / 2)
        addChild(gameOverLabel)

        let wait = SKAction.wait(forDuration: 2.0)
        let returnToCredits = SKAction.run { [weak self] in
            guard let self = self else { return }
            let creditsScene = CreditsScene(size: self.size)
            creditsScene.scaleMode = self.scaleMode
            let transition = SKTransition.fade(withDuration: 0.5)
            self.view?.presentScene(creditsScene, transition: transition)
        }
        run(SKAction.sequence([wait, returnToCredits]))
    }

    override func update(_ currentTime: TimeInterval) {
        if isGameEnding, let ball = currentBall {
            if ball.position.y < -50 || ball.position.x < -50 || ball.position.x > size.width + 50 {
                isGameEnding = false
                gameOver()
            }
        }

        if isBallFallingToHands, !hasCaughtBall, let ball = currentBall {
            let handsY = size.height - 150
            if ball.position.y <= handsY {
                ball.physicsBody?.affectedByGravity = false
                ball.physicsBody?.velocity = .zero
                ball.position.y = handsY
                hasCaughtBall = true
                isBallFallingToHands = false

                let wait = SKAction.wait(forDuration: 1.5)
                let dropAction = SKAction.run { [weak self] in
                    self?.dropBall()
                }
                run(SKAction.sequence([wait, dropAction]))
            }
        }
    }
}
