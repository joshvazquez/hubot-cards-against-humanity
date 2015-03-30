# Description
#   Cards Against Humanity for Hubot.
#
# Dependencies:
#   None
#
# Configuration:
#   None
#
# Commands:
#   !card game - request a game
#   !card join - join a game that hasn't started yet
#   !card start - stop waiting for players and start the game
#   !card end - manual game end (debug only)
#   !card help - view these commands
#
# Author:
#   Josh Vazquez
#
# Version:
#   0.3.0

# CONFIG
QUESTIONS_PATH = 'scripts/questions.json'
ANSWERS_PATH = 'scripts/answers.json'
MIN_PLAYERS = 1
MAX_HAND_SIZE = 10

# Load cards
fs = require 'fs'
questionsText = fs.readFileSync QUESTIONS_PATH
questions = JSON.parse questionsText
answersText = fs.readFileSync ANSWERS_PATH
answers = JSON.parse answersText

# Named messages
INFO_GAME_EXISTS = "A game already exists. Say \"!card join\" to join."
INFO_NO_GAME_EXISTS = "There is no game to start. Say \"!card game\" to set up a game."
INFO_GAME_IN_PROGRESS = "A game is already in progress."
INFO_NO_GAME_IN_PROGRESS = "No game in progress to join. Say \"!card game\" to set up a game."
INFO_WELCOME = "Welcome to Cards Against Humanity! To join the game, say \"!card join\"."
INFO_THANKS = "Thanks for playing!"
INFO_END = "Cards ended."
INFO_DUPLICATE_PLAYER = "Player is already in the list."
INFO_GAME_STARTED = "Game started! Sending hands via private message."
INFO_HOW_TO_SUBMIT = "Submit your answer by sending me a private message containing your card number from 1-10. Example: \"submit 3\". If a question requires multiple cards to be submitted, submit like this: \"submit 3 4 5\"."
INFO_ALL_PLAYERS_SUBMITTED = "All players have submitted their cards! Submissions are in random order."

Commands = 
  GAME_NEW : 0
  GAME_JOIN : 1
  GAME_START : 2
  GAME_SCORE : 3
  GAME_END : 4
  INFO : 5
  HELP : 6

g = 0
gameExists = no # need this or can just check `if g`, `if !g`?
gameStarted = no


class Game
  constructor: (channel, robot) ->
    @channel = channel
    @robot = robot

    # Modes for reading answer cards. Czar mode recommended when players are in a voice call
    @ReadModes = 
      BOT_READS : 0
      CZAR_READS : 1

    # Modes for voting.
    @VoteModes = 
      CHANNEL_VOTES : 0
      CZAR_VOTES : 1
  
    # Prepare
    @players = []
    @minPlayers = MIN_PLAYERS
    @maxHand = MAX_HAND_SIZE
    @isSubmissionPeriod = no
    @isVotingPeriod = no
    @roundNumber = 0
    @readMode = @ReadModes.BOT_READS
    @voteMode = @VoteModes.CZAR_VOTES
    @czarIndex = 0

    # Class-specific named messages
    @INFO_TOO_FEW_PLAYERS = "Not enough players. Need a total of " + @minPlayers + " players to start."

    # Build cards
    @questionDeck = []
    for i in [0..questions.length-1]
      @questionDeck[i] = new Card(questions[i])

    @answerDeck = []
    for i in [0..answers.length-1]
      @answerDeck[i] = new Card(answers[i])
    
    @discardQuestions = []
    @discardAnswers = []
    
    # Ready
    say(@channel, INFO_WELCOME)
    say(@channel, "Total question cards: " + @questionDeck.length)
    say(@channel, "Total answer cards: " + @answerDeck.length)
    
    
  joinPlayer: (msg) ->
    found = no
    for player in @players
      if msg.message.user.name is player.name
        console.log msg.message.user.name + " tried to join but is already in the list as " + player.name
        found = yes
        break
    if found
      say(@channel, INFO_DUPLICATE_PLAYER)
    else    
      p = new Player(msg, @robot)
      @players.push p
      joinMessage = p.name + " has joined the game. Players:"
      for player in @players
        joinMessage += " " + player.name
      joinMessage += ". When all players have joined, say \"!card start\"."
      @channel.send joinMessage

    
  startGame: ->
    if @players.length < @minPlayers
      say(@channel, @INFO_TOO_FEW_PLAYERS)
    else
      say(@channel, INFO_GAME_STARTED)
      say(@channel, INFO_HOW_TO_SUBMIT)
      for player in @players
        @fillHand(player)
        @sendHand(player)
      gameStarted = yes
      @playQuestion()


  playQuestion: ->
    @isVotingPeriod = no
    @czar = @chooseCzar()
    @roundNumber++
    
    # pulls a random question card out of the deck
    r = Math.floor(Math.random() * @questionDeck.length)
    card = @questionDeck.splice(r, 1)[0]

    @currentQuestion = card
    @channel.send "Round " + @roundNumber
    @channel.send card.text

    # players draw extra cards if necessary
    for player in @players
      toDraw = @currentQuestion.drawCount
      while toDraw > 0
        @drawCard(player)
        toDraw--
      @sendHand(player)

    @startSubmitting()


  startSubmitting: ->
    @isSubmissionPeriod = yes
    @playersToSubmit = []
    @submissions = []

    # put all players into "needs to submit" list
    for player in @players
      @playersToSubmit.push player


  submitCard: (msg) ->
    for player in @players
      if msg.message.user.name is player.name
        cards = []
        cardIndexes = []
        # get first card
        cards[0] = player.hand[msg.match[1]-1]
        cardIndexes.push msg.match[1]-1

        # get second card
        if msg.match[2]
          cards[1] = player.hand[msg.match[2]-1]
          cardIndexes.push msg.match[2]-1
          
        # get third card
        if msg.match[3]
          cards[2] = player.hand[msg.match[3]-1]
          cardIndexes.push msg.match[3]-1

        # enforce correct number of cards submitted
        if cardIndexes.length != @currentQuestion.playCount
          failSubmitMessage = "You must submit exactly " + @currentQuestion.playCount
          if @currentQuestion.playCount == 1
            failSubmitMessage += " card."
          else
            failSubmitMessage += " cards."
          @robot.send({user: {name: player.name}}, failSubmitMessage)
          return

        # remove cards from hand from largest index to smallest to not disrupt order while removing
        cardIndexes.sort()
        cardIndexes.reverse()
        for i in cardIndexes
          player.hand.splice(i, 1)[0]
        
        submitMessage = "You submitted:"
        for card in cards
          submitMessage += " " + card.text

        @robot.send({user: {name: player.name}}, submitMessage)
        @submissions.push({player: player, cards: cards})
        
        @fillHand(player)
        @sendHand(player)
        break

    # mark player as having submitted
    for i in [0..@playersToSubmit.length-1]
      if msg.message.user.name is @playersToSubmit[i].name
        @playersToSubmit.splice(i, 1)
        break

    # if players remain to submit
    if @playersToSubmit.length >= 1
      submitMessage = msg.message.user.name + " has submitted a card. Waiting for: "
      for player in @playersToSubmit
        submitMessage += " " + player.name
      @channel.send submitMessage
    else
      @showAnswers()


  showAnswers: ->
    @currentAnswer = 0
    @isSubmissionPeriod = no
    @isVotingPeriod = yes
    say(@channel, INFO_ALL_PLAYERS_SUBMITTED)

    blanks = (@currentQuestion.text.match(/_____/g) || []).length
    if blanks == 0
      @channel.send @currentQuestion.text

    # reorder the submissions randomly
    @randomizedSubmissions = @submissions
    @randomizedSubmissions.sort ->
      0.5 - Math.random()

    for s in @randomizedSubmissions
      @nextAnswer(s)
        
    @startVoting()

  nextAnswer: (submission) ->
    answerMessage = (@currentAnswer+1) + ":"

    cards = submission['cards']
    for card in cards
      answerMessage += " " + card.text

    filledInQuestion = @currentQuestion.text
    blanks = (@currentQuestion.text.match(/_____/g) || []).length
    if blanks > 0
      for i in [0..blanks-1]
        cardText = cards[i].text
        cardText = cardText[0..cardText.length-2]
        filledInQuestion = filledInQuestion.replace("_____", cardText)
      filledInQuestion = filledInQuestion.replace("(Draw 2, Pick 3) ", "")
      filledInQuestion = filledInQuestion.replace("(Pick 2) ", "")
      answerMessage = (@currentAnswer+1) + ": " + filledInQuestion

    if @readMode is @ReadModes.BOT_READS
      @channel.send answerMessage
    else if @readMode is @ReadModes.CZAR_READS
      @robot.send({user: {name: @czar.name}}, answerMessage)
    
    @currentAnswer++


  startVoting: ->
    if @voteMode is @VoteModes.CHANNEL_VOTES
      # TODO: not implemented. Should this mode be available?
      @channel.send "Voting time! Type \"!card vote #\" where # is the number prefixing the submission you want to vote for."
    else if @voteMode is @VoteModes.CZAR_VOTES
      @channel.send "The czar " + @czar.name + " is now voting."
      @robot.send({user: {name: @czar.name}}, "Voting time! Type \"vote #\" where # is the number prefixing the submission you want to vote for (numbers in the channel).")


  submitVote: (msg) ->
    if @voteMode is @VoteModes.CHANNEL_VOTES
      1
      # implement voteForCard()
    else if @voteMode is @VoteModes.CZAR_VOTES
      @robot.send({user: {name: @czar.name}}, "Thanks for your vote.")
      winner = @randomizedSubmissions[msg.match[1]-1]['player'].name
      @channel.send "This round's winner is " + winner + " with submission " + msg.match[1] + "."
      @randomizedSubmissions[msg.match[1]-1]['player'].score++
      @discardQuestions.push @currentQuestion
      @playQuestion(@channel)


  fillHand: (player) ->
    while player.hand.length < @maxHand
      @drawCard(player)

  drawCard: (player) ->
    r = Math.floor(Math.random() * @answerDeck.length)
    # pulls a random answer card out of the deck
    card = @answerDeck.splice(r, 1)[0]
    player.hand.push card


  sendHand: (player) ->
    # TODO: should we send in a single message to reduce message spam?
    @robot.send({user: {name: player.name}}, "Your hand:")
    displayHand = player.formatHand()
    for displayCard in displayHand
      @robot.send({user: {name: player.name}}, displayCard)


  chooseCzar: ->
    czar = @players[@czarIndex % @players.length]
    @czarIndex++
    return czar


  discardCard: (msg) ->
    for player in @players
      if msg.message.user.name is player.name
        msg.send "Card discarded."
        @channel.send msg.message.user.name + " just revealed to me in confidence that he or she doesn't know the meaning of the card: " + player.hand[msg.match[1]-1].text + " Don't worry " + msg.message.user.name + ", your secret's safe with me."
        player.hand.splice(msg.match[1]-1, 1) # remove card from hand
        @fillHand(player)
        @sendHand(player)
        break


  voteForCard: ->
    #


  showScore: ->
    scoreMessage = "Scores:"
    for player in @players
      scoreMessage += " " + player.name + " " + player.score + ","

    # strip trailing comma
    scoreMessage = scoreMessage[0..scoreMessage.length-2]
    @channel.send scoreMessage


  gameInfo: ->
    # show current czar, current round, questions in deck, answers in deck, player count
    console.log "Current round: " + @roundNumber
    console.log "Czar: " + @czar.name
    console.log "Czar index: " + @czarIndex
    console.log "Question cards remaining: " + @questionDeck.length
    console.log "Answer cards remaining: " + @answerDeck.length
    scoreMessage = "Scores:"
    for player in @players
      scoreMessage += " " + player.name + " " + player.score + ","
    console.log scoreMessage


class Player
  constructor: (msg, robot) ->
    @msg = msg
    @robot = robot
    @user = msg.message.user
    @name = msg.message.user.name
    @hand = []
    @score = 0
    @wonCards = []


  formatHand: ->
    displayHand = []
    for i in [0..@hand.length-1]
      displayHand[i] = i+1 + ": " + @hand[i].text # format hand as numbered list
    displayHand


class Card
  constructor: (text) ->
    @text = text
    @drawCount = 0
    @playCount = 1

    # count the number of blanks on the card to determine what kind of card it is
    blanks = (text.match(/_____/g) || []).length
    if blanks is 2 or @text.indexOf("(Pick 2)") > -1
      @playCount = 2
    else if blanks is 3 or @text.indexOf("(Draw 2, Pick 3)") > -1
      @drawCount = 2
      @playCount = 3
    

module.exports = (robot) =>
  robot.hear /(.*)/i, (msg) ->
    command = getCommand(msg)
    if command is Commands.GAME_NEW
      unless gameExists
        g = new Game(msg, robot)
        gameExists = yes
      else
        say(msg, INFO_GAME_EXISTS)
    else if command is Commands.GAME_JOIN
      unless gameExists
        say(msg, INFO_NO_GAME_IN_PROGRESS)
      else if gameStarted
        say(msg, INFO_GAME_IN_PROGRESS)
      else if gameExists
        g.joinPlayer(msg)
    else if command is Commands.GAME_START
      unless gameExists
        say(msg, INFO_NO_GAME_EXISTS)
      else if gameStarted
        say(msg, INFO_GAME_IN_PROGRESS)
      else if gameExists
        g.startGame(msg)
    else if command is Commands.GAME_SCORE
      if gameExists and g
        g.showScore()
    else if command is Commands.INFO
      if gameStarted and g
        g.gameInfo()
    else if command is Commands.HELP
      showHelp(msg)
    else if command is Commands.GAME_END
      if gameExists
        say(msg, INFO_THANKS)
        g.showScore()
        g = 0
        gameExists = no
        gameStarted = no
        say(msg, INFO_END)
        

  robot.respond /submit\s(\d+)[^\d*]?(\d+)?[^\d*]?(\d+)?/i, (msg) -> # responds to 1, 2, or 3 submissions
    if gameExists and g and g.isSubmissionPeriod
      g.submitCard(msg)
      

  robot.respond /vote\s(\d+)/i, (msg) ->
    if gameExists and g and g.isVotingPeriod
      g.submitVote(msg)
      

  robot.respond /discard\s(\d+)/i, (msg) ->
    if gameExists and g and gameStarted 
      g.discardCard(msg)
      

  robot.respond /next/i, (msg) ->
    if gameExists and g and g.isVotingPeriod and msg.message.user.name is g.czar.name
      console.log "czar called next answer"
      g.nextAnswer()
      

showHelp = (msg) ->
  msg.send "Available commands: !card game, !card join, !card start, !card help"
  msg.send "During a game, you can \"submit #\", \"vote #\", \"discard \". Submitting and voting only allowed at the appropriate times. You can discard a card at any time if you do not know what it means."


say = (msg, text) ->
  msg.send text


getCommand = (msg) ->
  if msg.match[1] is "!card game"
    Commands.GAME_NEW
  else if msg.match[1] is "!card join"
    Commands.GAME_JOIN
  else if msg.match[1] is "!card start"
    Commands.GAME_START
  else if msg.match[1] is "!card score"
    Commands.GAME_SCORE
  else if msg.match[1] is "!card end"
    Commands.GAME_END
  else if msg.match[1] is "!card info"
    Commands.INFO
  else if msg.match[1] is "!card help"
    Commands.HELP
