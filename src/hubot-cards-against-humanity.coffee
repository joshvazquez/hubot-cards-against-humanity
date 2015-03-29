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
#   0.1.0

# TODO: flag on each question indicating if the bot should require 2 cards to be played or not
# TODO: submissions should fill in the blanks when being read out if a question has blanks

# Update this for your own system
QUESTIONS_PATH = 'scripts/questions.json'
ANSWERS_PATH = 'scripts/answers.json'

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
INFO_HOW_TO_SUBMIT = "Submit your answer by sending me a private message containing your card number from 1-10. Example: \"submit 3\""
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
    @questionIDPool = []
    @answerIDPool = []  
    @players = []
    @playersToSubmit = []
    @minPlayers = 1
    @maxHand = 10
    @submissions = []
    @randomizedSubmissions = []
    @currentAnswer = 0
    @isSubmissionPeriod = no
    @votingPeriod = 0
    @roundNumber = 0
    @lastQuestion = 0
    @readMode = @ReadModes.BOT_READS
    @voteMode = @VoteModes.CZAR_VOTES
    @czarOrder = []
    @czarIndex = 0
    @czar = 0
    # TODO: any referencing issues with assigning myArray2 = myArray1 and then modifying/deleting myArray1?

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
    
    for i in [0..questions.length-1]
      @questionIDPool[i] = i
    
    
    for i in [0..answers.length-1]
      @answerIDPool[i] = i
    
    # Ready
    say(@channel, INFO_WELCOME)
    console.log "Total question cards: " + @questionDeck.length
    console.log "Total answer cards: " + @answerIDPool.length
    
    
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
        joinMessage = joinMessage + " " + player.name
      joinMessage = joinMessage + ". When all players have joined, say \"!card start\"."
      @channel.send joinMessage

    
  startGame: ->
    if @players.length < @minPlayers
      say(@channel, @INFO_TOO_FEW_PLAYERS)
    else
      say(@channel, INFO_GAME_STARTED)
      say(@channel, INFO_HOW_TO_SUBMIT)
      for player in @players
        console.log "Filling hand for " + player.name
        @fillHand(player)
        console.log "Sending hand for " + player.name
        @sendHand(player)
      gameStarted = yes
      @playQuestion()


  playQuestion: ->
    @votingPeriod = 0
    @currentAnswer = 0
    @lastQuestion = 0
    @czar = @chooseCzar()
    @roundNumber++
    
    # pulls a random question card out of the deck
    r = Math.floor(Math.random() * @questionDeck.length)
    card = @questionDeck.splice(r, 1)[0]

    @lastQuestion = card
    @channel.send "Round " + @roundNumber
    @channel.send card.text
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
        @robot.send({user: {name: player.name}}, "You submitted: " + player.hand[msg.match[1]-1])
        @submissions.push({player: player, submission:player.hand.splice(msg.match[1]-1, 1)}) # move submission from hand to submissions
        if (msg.match[2]-1)
          console.log "received second card"
        @fillHand(player)
        @sendHand(player)
        break
    for i in [0..@playersToSubmit.length-1]
      if msg.message.user.name is @playersToSubmit[i].name
        @playersToSubmit.splice(i, 1)
        break
    if @playersToSubmit.length >= 1
      submitMessage = msg.message.user.name + " has submitted a card. Waiting for: "
      for player in @playersToSubmit
        submitMessage = submitMessage + " " + player.name
      @channel.send submitMessage
    else
      @showAnswers()


  showAnswers: ->
    @isSubmissionPeriod = no
    @votingPeriod = 1
    say(@channel, INFO_ALL_PLAYERS_SUBMITTED)
    @channel.send @lastQuestion.text
    @nextAnswer()


  nextAnswer: -> # send the next submission to the channel or czar
    @randomizedSubmissions = @submissions
    @randomizedSubmissions.sort ->
      0.5 - Math.random()
    if @currentAnswer >= @randomizedSubmissions.length
      @currentAnswer = 0
      @startVoting()
    else
      if @readMode is @ReadModes.BOT_READS
        for s in @randomizedSubmissions
          @channel.send (@currentAnswer+1) + ": " + s['submission']
          @currentAnswer++
          console.log "@currentAnswer: " + @currentAnswer
      else if @readMode is @ReadModes.CZAR_READS
        for s in @randomizedSubmissions
          @robot.send({user: {name: @czar.name}}, ((@currentAnswer+1) + ": " + s['submission']))
          @currentAnswer++
          console.log "@currentAnswer: " + @currentAnswer
          
      if @currentAnswer >= @randomizedSubmissions.length # duplicate code
        console.log "second time @currentAnswer >= @randomizedSubmissions.length"
        @currentAnswer = 0
        @startVoting()


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
      @discardQuestions.push @lastQuestion
      @playQuestion(@channel)


  fillHand: (player) ->
    while player.hand.length < @maxHand
      r = Math.floor(Math.random() * @answerIDPool.length)
      c = answers[@answerIDPool.splice(r, 1)[0]] # removes a random answer card from the pool and returns it
      player.hand.push c
    # TODO: show hand


  sendHand: (player) ->
    # TODO: should we send in a single message to reduce message spam?
    @robot.send({user: {name: player.name}}, "Your hand:")
    hand = player.formatHand()
    for card in hand
      @robot.send({user: {name: player.name}}, card)


  chooseCzar: ->
    if !@czarOrder or @czarOrder.length is 0
      console.log "@czarOrder empty"
      for player in @players
        console.log "push player to @czarOrder"
        @czarOrder.push player # join order determines czar order
      console.log "PATH 1 return @czarOrder[@czarIndex++]"
      return @czarOrder[@czarIndex++] # return czar player and set next czar
    else
      console.log "@czarOrder not empty"
      if @czarIndex >= @czarOrder.length
        console.log "@czarIndex >= @czarOrder.length"
        @czarIndex = 0 # back to top of list
        console.log "PATH 2 return @czarOrder[@czarIndex++]"
        return @czarOrder[@czarIndex++] # return czar player and set next czar
      else
        console.log "PATH 3 return @czarOrder[@czarIndex++]"
        return @czarOrder[@czarIndex++] # return czar player and set next czar


  discardCard: (msg) ->
    for player in @players
      if msg.message.user.name is player.name
        msg.send "Card discarded."
        @channel.send msg.message.user.name + " just revealed to me in confidence that he or she doesn't know the meaning of the card: " + player.hand[msg.match[1]-1] + " Don't worry " + msg.message.user.name + ", your secret's safe with me."
        player.hand.splice(msg.match[1]-1, 1) # remove card from hand
        @fillHand(player)
        @sendHand(player)
        break


  voteForCard: ->
    #


  showScore: ->
    scoreMessage = "Scores:"
    for player in @players
      scoreMessage = scoreMessage + " " + player.name + " " + player.score + ","
    @channel.send scoreMessage


  gameInfo: ->
    # show current czar, current round, questions in deck, answers in deck, player count
    console.log "Current round: " + @roundNumber
    console.log "Czar: " + @czar.name
    console.log "Czar order: " + @czarOrder
    console.log "Czar index: " + @czarIndex
    console.log "@czarOrder[0]: " + @czarOrder[0]
    console.log "Question cards remaining: " + @questionIDPool.length
    console.log "Answer cards remaining: " + @answerIDPool.length
    scoreMessage = "Scores:"
    for player in @players
      scoreMessage = scoreMessage + " " + player.name + " " + player.score + ","
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
      displayHand[i] = i+1 + ": " + @hand[i] # format hand as numbered list
    displayHand


class Card
  constructor: (text) ->
    @text = text
    @drawCount = 0
    @playCount = 1

    # count the number of blanks on the card to determine what kind of card it is
    blanks = (text.match(/_____/g) || []).length
    if blanks is 2
      @playCount = 2
    else if blanks is 3
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
      if gameExists and g
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
    if gameExists and g and g.votingPeriod is 1
      g.submitVote(msg)
      

  robot.respond /discard\s(\d+)/i, (msg) ->
    if gameExists and g and gameStarted 
      g.discardCard(msg)
      

  robot.respond /next/i, (msg) ->
    if gameExists and g and g.votingPeriod is 1 and msg.message.user.name is g.czar.name
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
