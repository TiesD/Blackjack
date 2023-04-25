// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";
import "@chainlink/contracts/src/v0.8/VRFV2WrapperConsumerBase.sol";

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

contract BlackJack is VRFV2WrapperConsumerBase, ConfirmedOwner {

    //Hardcoded sepolia addresses
    address constant linkAddress = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address constant wrapperAddress = 0xab18414CD93297B0d12ac29E63Ca20f515b3DB46;
    uint32 constant callbackGas = 1_000_000;
    uint32 constant numWords = 1;
    uint16 constant requestConfirmations = 3;

    event DeckRequest(uint256 requestId);
    event Status(uint256 requestId, bool isDone);
    mapping(uint256 => DeckStatus) public requestStatus;


        struct DeckStatus {
        uint256 fees;
        uint256 lobbyID;
        bool fulfilled;
    }


    function generate() internal returns(uint256){

        uint256 request = requestRandomness(
            callbackGas,
            requestConfirmations,
            numWords
        );

        requestStatus[request] = DeckStatus({
            fees: VRF_V2_WRAPPER.calculateRequestPrice(callbackGas),
            lobbyID: request,
            fulfilled: false
        });
        emit DeckRequest(request);
        return request;
    }

     function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        require(requestStatus[requestId].fees  > 0, "Request does not exist");
        
        Lobby storage curr = lobbies[requestId];
        DeckStatus storage status = requestStatus[requestId];

        status.fulfilled = true;
        curr.lobbyid = requestId;
        curr.isReady = true;
        emit GameReady(requestId);
   }
    

    //Will add more events later
    event GameCreated(uint256 lobbyID, address player, uint256 bet);
    event GameReady(uint256 lobbyID);
    event JoinedLobby(uint256 lobbyID, address player, uint256 bet);
    event HandResult(uint256 lobbyID, address player, bool win);
    event CardsDealt(uint256[] cards, address player);

    //LobbyID => Lobby
    mapping(uint256 => Lobby) public lobbies;

    enum PlayerDecision {
        HIT,
        STAND
    }
    /*
    *  Lobby struct, contains all the information about the lobby, including the players, their cards, their bets, and the deck.
    *  There is probably a better way to organize this data.
    */
    struct Lobby{
        uint256 seed;
        address[] players;
        mapping(address => uint256) cardTotals;
        mapping(address => uint256) playerBets;
        mapping(address => uint256[]) playerCards;
        mapping(address => bool) playerState;
        mapping(address => bool) playerTurn;
        uint256 lobbyid;
        uint16 maxPlayers;
        bool isReady; 
        uint256[] dealerCards;
    }


    constructor() ConfirmedOwner(msg.sender) VRFV2WrapperConsumerBase(linkAddress, wrapperAddress) {}




    function createGame(uint16 _maxPlayers) public payable returns(bool) {
        require(msg.value > 0, "You must bet at least 1 wei");

        //Make a request to the backend card generation, we use the ID returned by it to identify the lobby.
        uint256 request = generate();
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

    uint8[52] deck = [11,2,3,4,5,6,7,8,9,10,10,10,10,11,2,3,4,5,6,7,8,9,10,10,10,10,11,2,3,4,5,6,7,8,9,10,10,10,10,11,2,3,4,5,6,7,8,9,10,10,10,10];

    function getCard(uint256 _lobbyid) internal returns(uint8){
        uint256 seed = lobbies[_lobbyid].seed;
        uint8 card = deck[uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, seed))) % 52];
        return card;
    }
    
    function startGame(uint256 _lobbyid) public {
        require(msg.sender == lobbies[_lobbyid].players[0], "Only the creator can start the game");
        require(lobbies[_lobbyid].isReady == true, "Lobby is not ready");
        require(lobbies[_lobbyid].players.length > 1, "Not enough players");





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
            if((curr.cardTotals[curr.players[i]] > dealerTotal && curr.cardTotals[curr.players[i]] < 22) || (dealerTotal > 21  && curr.cardTotals[curr.players[i]] < 22)){
                //Win
                (bool sent, bytes memory data) = payable(curr.players[i]).call{value: curr.playerBets[curr.players[i]] * 2}("");
                require(sent, "Failed to send Ether");
                emit HandResult(_lobbyid, curr.players[i], true);
            }else if((curr.cardTotals[curr.players[i]] > 21) || (curr.cardTotals[curr.players[i]] < dealerTotal && dealerTotal < 22) ){
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
