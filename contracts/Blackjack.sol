// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "./DeckGeneration.sol";

/*
*   IMPORTANT NOTES:
*   - The majority of the logic in this contract relies on the lobbyID, which is returned in createGame() and is used to identify the lobby.
*   - Most requirements about msg.value are just placeholders for values that will be changed later.
*   - I am worried about how the storage will work for this game, I was told that objects in the LobbyId => Lobby mapping will persist between calls.
*   - This is not deployment ready.
*   
*   A small summary of a game:
*   1. Player 1 creates a game with a bet of 1 wei, and a max of 2 players.
*   2. This contract calls the DeckGeneration contract to generate a deck of cards.
*   3. The DeckGeneration contract calls the Chainlink VRF to generate a random number.
*   4. The Chainlink VRF returns the random number to the DeckGeneration contract.
*   5. The DeckGeneration contract shuffles the deck and calls the recieveCards() function in this contract.
*   6. recieveCards() stores the deck in the lobby struct and sets the lobby to ready.
*   7. Player 2 joins the lobby with a bet of 1 wei.
*   8. Player 2 is dealt 2 cards, and the dealer is dealt 2 cards.
*   9. Player 1 is dealt 2 cards.
*   10. Player 1 is prompted to make a decision, either hit or stand.
*/

contract BlackJack {




    //Unused
    address payable public owner;
    DeckGeneration deckGeneration;

    //Will add more events later
    event GameCreated(uint256 lobbyID, address player, uint256 bet);
    event GameReady(uint256 lobbyID);
    event JoinedLobby(uint256 lobbyID, address player, uint256 bet);
    event HandResult(uint256 lobbyID, address player, bool win);
    event CardsDealt(uint256[] cards, address player);

    //LobbyID => Lobby
    mapping(uint256 => Lobby) public lobbies;

    //Vulnerable bc external
    function recieveCards(uint8[52] memory deck, uint256 lobbyID) external {
        require(msg.sender == address(deckGeneration), "Can only be called by deck contract");
        lobbies[lobbyID].deck = deck;
        lobbies[lobbyID].isReady = true;
        emit GameReady(lobbyID);
    }

    enum PlayerDecision {
        HIT,
        STAND
    }
    /*
    *  Lobby struct, contains all the information about the lobby, including the players, their cards, their bets, and the deck.
    *  There is probably a better way to organize this data.
    */
    struct Lobby{
        uint8[52] deck;
        address[] players;
        mapping(address => uint256) cardTotals;
        mapping(address => uint256) playerBets;
        mapping(address => uint256[]) playerCards;
        mapping(address => bool) playerState;
        mapping(address => bool) playerTurn;
        uint32 cardIndex;
        uint256 lobbyid;
        uint16 maxPlayers;
        bool isReady; 
        uint256[] dealerCards;
    }


    constructor()  {
        owner = payable(msg.sender);
        deckGeneration = new DeckGeneration();
    }
        //TODO CARDS ARE VISIBLE IN TX DATA
    function createGame(uint16 _maxPlayers) public payable returns(bool) {
        require(msg.value > 0, "You must bet at least 1 wei");

        //Make a request to the backend card generation, we use the ID returned by it to identify the lobby.
        uint256 request = deckGeneration.generate();
        //Lobby setup
        lobbies[request].lobbyid = request;
        lobbies[request].players.push(msg.sender);
        lobbies[request].playerBets[msg.sender] = msg.value;
        lobbies[request].maxPlayers = _maxPlayers;
        lobbies[request].isReady = false;
        lobbies[request].playerTurn[msg.sender] = false;
        lobbies[request].playerState[msg.sender] = false;

        emit GameCreated(request, msg.sender, msg.value);
        return true;
    }


    function joinGame(uint256 _lobbyid) public payable returns(bool){
        require (lobbies[_lobbyid].lobbyid == _lobbyid, "Lobby does not exist");
        require(msg.value > 0, "You must bet at least 1 wei");
        require(lobbies[_lobbyid].players.length < lobbies[_lobbyid].maxPlayers, "Lobby is full");
        require(lobbies[_lobbyid].isReady == true, "Lobby is ready");

        Lobby storage curr = lobbies[_lobbyid];

        //Adds user to the lobby with their bet.
        curr.players.push(msg.sender);
        curr.playerBets[msg.sender] = msg.value;
        curr.playerTurn[msg.sender] = false;
        curr.playerState[msg.sender] = false;
        emit JoinedLobby(_lobbyid, msg.sender, msg.value);
        return true;
    }
    
    function startGame(uint256 _lobbyid) public {
        require(msg.sender == lobbies[_lobbyid].players[0], "Only the creator can start the game");
        require(lobbies[_lobbyid].isReady == true, "Lobby is not ready");
        //Need enough cards for everyone, +2 is for the dealer.
        require(lobbies[_lobbyid].deck.length > ((lobbies[_lobbyid].players.length * 2) + 2), "Not enough cards in deck");

         Lobby storage curr = lobbies[_lobbyid];
        uint32 i;
        /*
        *   Worried about this logic, but should work because we have a full deck.
        */
        for(i = 0; i < curr.players.length; i+=2){
            curr.playerCards[curr.players[i]][0] = curr.deck[i];
            curr.playerCards[curr.players[i]][1] = curr.deck[i+1];


            emit CardsDealt(curr.playerCards[curr.players[i]], curr.players[i]);

            //Not sure if the deletes are needed since I keep track of the index now.
            delete curr.deck[i];
            delete curr.deck[i+1];
        }
        //Give cards to dealer.
        curr.dealerCards[0] = curr.deck[i+1];
        curr.dealerCards[1] =  curr.deck[i + 2];
        //Cards dealt to dealer
        emit CardsDealt(curr.dealerCards, address(0));

        //Not sure if the deletes are needed since I keep track of the index now.
        delete curr.deck[i+1];
        delete curr.deck[i+2];
        //Set the card index
        curr.cardIndex = i + 3;


        if(curr.dealerCards[0] == 11){
            //TODO: Insurance
        }

        //Counting card totals, probably will find a better way to do this.

        for(uint8 j = 0; j < curr.players.length; j++){
            curr.cardTotals[curr.players[j]] = curr.playerCards[curr.players[j]][0] + curr.playerCards[curr.players[j]][1];

            //if the card total is 22, make it 12 (Double ace) - I know this isnt the right way to do this.
            if(curr.cardTotals[curr.players[j]] == 22){
                curr.cardTotals[curr.players[j]] = 12;
            }
        }
        //Make the first player able to play.
        curr.playerTurn[curr.players[0]] = true;

    }

    function playCurrentHand(PlayerDecision _choice, uint256 _lobbyid) public {
        //Hit is 0, Stand is 1
        require(_choice == PlayerDecision.HIT || _choice == PlayerDecision.STAND, "Invalid choice");
        //Check if the player is in the lobby and can play
        require(lobbies[lobbies[_lobbyid].lobbyid].playerTurn[msg.sender] == true, "Player has already played / Can't play yet");

        Lobby storage curr = lobbies[_lobbyid];

        if(_choice == PlayerDecision.HIT){
            //This is where I think there can be issues with not having enough cards.
            curr.playerCards[msg.sender].push(curr.deck[curr.cardIndex]);

            emit CardsDealt(curr.playerCards[msg.sender], msg.sender);

            curr.cardIndex++;
            curr.cardTotals[msg.sender] += curr.playerCards[msg.sender][curr.playerCards[msg.sender].length - 1];

            //Check if the player has busted
            if(curr.cardTotals[msg.sender] > 21){

                curr.playerState[msg.sender] = false;
            }
        }
         if(_choice == PlayerDecision.STAND){
            curr.playerTurn[msg.sender] = false;

            //make the next player able to play
            for(uint8 i = 0; i < lobbies[_lobbyid].players.length; i++){
                if(curr.playerTurn[curr.players[i]] == true){
                    curr.playerTurn[curr.players[i+1]] = true;
                    break;
                }
            }
        }
        //if the last player has played
        curr.playerTurn[msg.sender] = false;

        if(curr.playerTurn[curr.players[curr.players.length - 1]] == false){
            settleGame(_lobbyid);
        }
        //WILL WRITE REST OF THE LOGIC LATER
    }


    function settleGame(uint256 _lobbyid) internal {
        //get the dealer total
        Lobby storage curr  = lobbies[_lobbyid];
        uint256 dealerTotal = curr.dealerCards[0] + curr.dealerCards[1];
        
        if(dealerTotal <= 16){
            while(dealerTotal <= 21){
            curr.dealerCards.push(curr.deck[curr.cardIndex]);
            emit CardsDealt(lobbies[_lobbyid].dealerCards, address(0));
            curr.cardIndex++;
            dealerTotal += curr.deck[curr.cardIndex];
            }
        }
         

         for(uint8 i = 0; i < curr.players.length ; i++){
            if((curr.cardTotals[curr.players[i]] > dealerTotal && curr.cardTotals[curr.players[i]] < 21) || (dealerTotal > 21  && curr.cardTotals[curr.players[i]] < 21)){
                //Win
                (bool sent, bytes memory data) = payable(curr.players[i]).call{value: curr.playerBets[curr.players[i]] * 2}("");
                require(sent, "Failed to send Ether");
                emit HandResult(_lobbyid, curr.players[i], true);
            }else if(curr.cardTotals[curr.players[i]] > dealerTotal && curr.cardTotals[curr.players[i]] < 21){
                //Lose
                emit HandResult(_lobbyid, curr.players[i], false);
            }else {
                //Push
                (bool sent, bytes memory data) = payable(curr.players[i]).call{value: curr.playerBets[curr.players[i]]}("");
                require(sent, "Failed to send Ether");
                emit HandResult(_lobbyid, curr.players[i], true);
            }
         }

    }








}