//+------------------------------------------------------------------+
//|                                  Patinhas_SpreadMiner_Bot_v1.mq5 |
//|          Copyright 2018, Heraldo L. S. Almeida (heraldo@ufrj.br) |
//|                                 https://www.del.ufrj.br/~heraldo |
//+------------------------------------------------------------------+

#property copyright "Copyright 2018, Heraldo L. S. Almeida (heraldo@ufrj.br)"
#property link      "https://www.del.ufrj.br/~heraldo"
#property version   "1.00"

//--------------------------------------------------------------------
// SPREAD-MINER BOT
//
//   Parameters:
//
//     N = number of orders initially placed at each end
//     V = initial volume offered by order
//     S = minimum admissible spread for trading
//
//   This bot implements a "market-making" strategy as follows:
//
//     1) It performs passive trading (pending limit orders only).
//
//     2) All orders are placed with initial volume V.
//
//     3) At every book event, the bid(ask) price is determined as the
//        price of the best buy(sell) offer placed by other players,
//        without considering the robot's own orders.
//        
//     4) Initially, N buy limit orders are placed at bid+1 and N sell
//        limit orders are placed at ask-1, so that all orders are
//        placed ahead of all other player's orders in the book.
//    
//     5) Whenever a buy(sell) order is totally executed, a new opposite
//        order is placed at ask-1(bid+1), ahead of all other orders.
//
//        Corolary: there will always be a total of 2N pending orders
//                  simultaneously active 
//
//     6) Any buy(sell) order with price lower(higher) than bid(ask)
//        or higher(lower) than bid+1(ask-1) is automatically repriced
//        to bid+1(ask-1).
//
//     7) Before sending new orders or repricing existing ones, the
//        compliance to the minimum spread is checked. Whenever the
//        distance between robot's buy and sell orders in the new setup
//        is below S, buy orders are repriced to (bid+ask)/2 - S/2,
//        and sell orders are repriced to (bid+ask)/2 + S/2.
//
//--------------------------------------------------------------------

//--------------------------------------------------------------------
// USER-TUNNABLE ROBOT PARAMETERS 
//--------------------------------------------------------------------

#define VOLUME_STEPS_PER_ORDER  2  // volume to be offered per order,
                                    // in volume steps

#define ORDERS_PER_END          1   // number of orders initially
                                    // placed at each end

//--------------------------------------------------------------------
// TRANSACTION COST PARAMETERS (DEPENDENT ON THE BROKER)
//--------------------------------------------------------------------

#define COMMISSIONS  1.00    // brokerage commission
                             // (fixed cost per transaction)
                             
#define FEES         0.025   // brokerage fees 
                             // (% of transaction value)

//--------------------------------------------------------------------
// AUTOMATICALLY-TUNNED PARAMETERS 
//--------------------------------------------------------------------

#define VOLUME_PER_ORDER ( VOLUME_STEPS_PER_ORDER * SymbolInfoDouble(Symbol(),SYMBOL_VOLUME_STEP) )

#define TRANSACTION_COST ( COMMISSIONS + (FEES/100.0) * VOLUME_PER_ORDER * SymbolInfoDouble(Symbol(),SYMBOL_ASK) )
                           
#define MIN_SPREAD       ( ( ceil ( 2 * TRANSACTION_COST / VOLUME_PER_ORDER / SymbolInfoDouble(Symbol(),SYMBOL_TRADE_TICK_SIZE) ) + 1) * SymbolInfoDouble(Symbol(),SYMBOL_TRADE_TICK_SIZE) )

//--------------------------------------------------------------------
// SIMPLIFIED PARAMETERS USED IN THE MQL5 CODE 
//--------------------------------------------------------------------

#define N ORDERS_PER_END      // total number of simultaneously active orders
#define V VOLUME_PER_ORDER    // intial volume per order
#define C TRANSACTION_COST    // cost per executed order
#define S MIN_SPREAD          // minimum admissible spread

//--------------------------------------------------------------------
// GLOBAL DATA - Spread Miner Setup Definition
//--------------------------------------------------------------------

double currentPosition  = 0.0;
double currentBalance   = 0.0;
double accumulatedCosts = 0.0;

double recommendedBuyPrice  = 0.0;
double recommendedSellPrice = 0.0;

double firstBookEvent = true;

//--------------------------------------------------------------------
// INIT EVENT
//--------------------------------------------------------------------

int OnInit()
{
   PrintFormat ( "+---------------------------------------------+ ");
   PrintFormat ( "| SPREAD MINER BOT version 1.00 (May 8, 2018) |");
   PrintFormat ( "+---------------------------------------------+ ");
   PrintFormat ( " ");
   
   MarketBookAdd(Symbol());

   PrintFormat ( "%s >> Bot has been successfully initialized." ,  Symbol()    );
   PrintFormat ( "%s >>                                       " ,  Symbol()    );
   PrintFormat ( "%s >> N = %6d                               " ,  Symbol(), N );
   PrintFormat ( "%s >> V = %6.1f                             " ,  Symbol(), V );
   PrintFormat ( "%s >> C = %6.2f                             " ,  Symbol(), C );
   PrintFormat ( "%s >> S = %6.2f                             " ,  Symbol(), S );
   PrintFormat ( "%s >>                                       " ,  Symbol()    );
   
   MqlBookInfo book[]; 

   if ( ! MarketBookGet ( Symbol() , book ) )
   {
      FatalError("Could not read the book. Robot will be shut down.");
      ExpertRemove();
      return(INIT_SUCCEEDED);
   }

//   for ( int i = 0 ; i < ArraySize(book)-1 ; i++ )
//   {
//      PrintFormat ( "%3d :  type = %s  price = %5.2f  volume = %9.0f" , i , EnumToString(book[i].type) , book[i].price , book[i].volume );
//   }
//
//   ExpertRemove();
   
   return(INIT_SUCCEEDED);
}

//--------------------------------------------------------------------
// DEINIT EVENT
//--------------------------------------------------------------------

void OnDeinit(const int reason)
{
   MarketBookRelease(Symbol());   
   
   PrintFormat ( "%s >> Bot has been successfully shut down." ,  Symbol() );
}

//--------------------------------------------------------------------
// TRADETRANSACTION EVENT
//--------------------------------------------------------------------

void OnTradeTransaction
(
   const MqlTradeTransaction &trans, 
   const MqlTradeRequest     &request, 
   const MqlTradeResult      &result
) 

{ 
   //-----------------------------------------------------------------
   // ignore events not linked to the target symbol 
   //-----------------------------------------------------------------
   
   if ( trans.symbol != Symbol() ) return;
   
   //PrintFormat ( "%s >> OnTradeEvent : %30s order %d order_type %30s order_state %30s deal_type %30s volume %5f price %6.2f )" ,
   //              Symbol(), EnumToString(trans.type), trans.order, EnumToString(trans.order_type) , EnumToString(trans.order_state) , EnumToString(trans.deal_type) , trans.volume , trans.price  );
   
   //-----------------------------------------------------------------
   // at every DEAL_ADD event:
   //   update current position and balance
   //-----------------------------------------------------------------
   
   if ( trans.type == TRADE_TRANSACTION_DEAL_ADD )
   {
      double volume = 0.0;
      
      switch ( trans.deal_type ) 
      { 
         case DEAL_TYPE_BUY           : 
         case DEAL_TYPE_SELL_CANCELED : volume =  trans.volume; break;
         case DEAL_TYPE_SELL          : 
         case DEAL_TYPE_BUY_CANCELED  : volume = -trans.volume;
      }
      
      currentPosition += volume;
      currentBalance  -= volume * trans.price;

      PrintFormat ( "%s >> Deal %4.0f @ %5.2f" , Symbol() , volume , trans.price );
   }   

   //-----------------------------------------------------------------
   // at every ORDER_DELETE event
   //   place a new order in the opposite direction
   //-----------------------------------------------------------------

   if ( trans.type == TRADE_TRANSACTION_ORDER_DELETE )
   {
      ENUM_ORDER_TYPE orderType = trans.order_type;
      
      double positionValue = currentPosition * ( currentPosition > 0 ? SymbolInfoDouble(Symbol(),SYMBOL_BID) : SymbolInfoDouble(Symbol(),SYMBOL_ASK) );

      PrintFormat ( "%s >> An %s has been closed with status %s" , Symbol() , EnumToString(orderType) , EnumToString(trans.order_state) );

      switch ( trans.order_state ) 
      { 
         case ORDER_STATE_FILLED   : 
         
            accumulatedCosts += C;              
            orderType = ( orderType == ORDER_TYPE_BUY_LIMIT ) ?  ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_LIMIT;                  
         
         case ORDER_STATE_CANCELED : 
         case ORDER_STATE_REJECTED : 
         case ORDER_STATE_EXPIRED  : 
         
            if ( ! placeNewOrder ( orderType ) ) { ExpertRemove(); return; } 
      }      

      PrintFormat ( "%s >> Balance: %10.2f  Position: %10.2f  Gross Profit: %10.2f  Costs: %10.2f  Net Profit: %10.2f",
                             Symbol() , 
                             currentBalance , 
                             positionValue , 
                             positionValue + currentBalance ,
                             accumulatedCosts ,
                             positionValue + currentBalance - accumulatedCosts );
   }
}
         
//--------------------------------------------------------------------
// BOOK EVENT
//--------------------------------------------------------------------

void OnBookEvent(const string &symbol)
{

   //-----------------------------------------------------------------
   // 1. Abort if symbol is other than the target instrument
   //-----------------------------------------------------------------

   if ( symbol != Symbol() ) return;
   
   //-----------------------------------------------------------------
   // 2. Read the order book
   //-----------------------------------------------------------------

   MqlBookInfo book[]; 

   if ( ! MarketBookGet ( Symbol() , book ) )
   {
      FatalError("Could not read the book. Robot will be shut down.");
      return;
   }

   //-----------------------------------------------------------------
   // 3. Determine the position of bid/ask prices in the book
   //-----------------------------------------------------------------

   int iAsk = 0;
   int iBid = 0;
   
   for ( int i = 0 ; i < ArraySize(book)-1 ; i++ )
   {
      if ( book[i].type != book[i+1].type )
      {
         iAsk = i;
         iBid = i+1;
         break;
      }
   }

   if ( iAsk == iBid )
   {
      PrintFormat ( "%s >> WARNING: The offer book is empty at least in one of its sides." , Symbol() );
      return;
   }

   //-----------------------------------------------------------------
   // 4. Determine the "market" bid/ask prices,
   //    i.e., bid/ask prices without the orders placed by the bot
   //-----------------------------------------------------------------

   double vAsk1 = (double) book[iAsk-1].volume;
   double vAsk0 = (double) book[iAsk  ].volume;
   double vBid0 = (double) book[iBid  ].volume;
   double vBid1 = (double) book[iBid+1].volume;
   
   int nOrders = OrdersTotal();

   for ( int i = 0 ; i < nOrders ; i++ )
   {
      ResetLastError();
      
      ulong ticket = OrderGetTicket(i);
      
      if ( ticket != 0 )
      {
         double price  = OrderGetDouble(ORDER_PRICE_OPEN);
         double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
         
         if      ( price == book[iAsk-1].price ) vAsk1 -= volume;
         else if ( price == book[iAsk  ].price ) vAsk0 -= volume; 
         else if ( price == book[iBid  ].price ) vBid0 -= volume; 
         else if ( price == book[iBid+1].price ) vBid1 -= volume;
      }
   }
   
   if ( vAsk0 <= 0.0 ) { iAsk--; if ( vAsk1 <= 0.0 ) iAsk--; }
   if ( vBid0 <= 0.0 ) { iBid++; if ( vBid1 <= 0.0 ) iBid++; }
   
   //-----------------------------------------------------------------
   // 5. Determine the prices where the existing orders can stay 
   //-----------------------------------------------------------------
    
   double ask0 = book[iAsk].price;   
   double bid0 = book[iBid].price;
   double ask1 = ask0 - SymbolInfoDouble(Symbol(),SYMBOL_TRADE_TICK_SIZE);
   double bid1 = bid0 + SymbolInfoDouble(Symbol(),SYMBOL_TRADE_TICK_SIZE);

   //-----------------------------------------------------------------
   // 6. Determine the price bounds for compliance to minimum spread 
   //-----------------------------------------------------------------

   double maxBid = ask1 - S;
   double minAsk = bid1 + S;

   //-----------------------------------------------------------------
   // 7. Determine new recommended buy/sell prices 
   //-----------------------------------------------------------------

   recommendedBuyPrice  = ( bid1 <= maxBid ) ? bid1 : maxBid;
   recommendedSellPrice = ( ask1 >= minAsk ) ? ask1 : minAsk;

   recommendedBuyPrice  = floor ( recommendedBuyPrice  / SymbolInfoDouble(Symbol(),SYMBOL_TRADE_TICK_SIZE) ) * SymbolInfoDouble(Symbol(),SYMBOL_TRADE_TICK_SIZE);
   recommendedSellPrice = ceil  ( recommendedSellPrice / SymbolInfoDouble(Symbol(),SYMBOL_TRADE_TICK_SIZE) ) * SymbolInfoDouble(Symbol(),SYMBOL_TRADE_TICK_SIZE);
   
   //-----------------------------------------------------------------
   // 8. Reprice all orders outside { bid , bid+1 , ask-1 , ask }
   //    to either bid+1 (buy orders) or ask-1 (sell orders). 
   //-----------------------------------------------------------------

   nOrders = OrdersTotal();

   for ( int i = 0 ; i < nOrders ; i++ )
   {
      ResetLastError();
      
      ulong ticket = OrderGetTicket(i);
      
      if ( ticket != 0 )
      {
         ENUM_ORDER_TYPE type   = (ENUM_ORDER_TYPE) OrderGetInteger(ORDER_TYPE);
         double          price  = OrderGetDouble(ORDER_PRICE_OPEN);
         
         if ( type == ORDER_TYPE_BUY_LIMIT  && ( price > recommendedBuyPrice  || ( price < recommendedBuyPrice  && price != bid0 ) ) )
         {
            if ( price <  recommendedBuyPrice ) PrintFormat ( "price <  recommendedBuyPrice :   price = %5.2f  recommendedBuyPrice = %5.2f" , price , recommendedBuyPrice );
            if ( price == recommendedBuyPrice ) PrintFormat ( "price == recommendedBuyPrice :   price = %5.2f  recommendedBuyPrice = %5.2f" , price , recommendedBuyPrice );
            if ( price >  recommendedBuyPrice ) PrintFormat ( "price >  recommendedBuyPrice :   price = %5.2f  recommendedBuyPrice = %5.2f" , price , recommendedBuyPrice );
            PrintFormat ( "%s >>  price = %15.9f  bid0 = %5.2f  bid1 = %5.2f  maxBid = %5.2f recommendedBuyPrice = %15.9f" , Symbol() , price , bid0 , bid1 , maxBid , recommendedBuyPrice );
            repriceOrder ( ticket , recommendedBuyPrice  ); 
         }
         if ( type == ORDER_TYPE_SELL_LIMIT && ( price < recommendedSellPrice || ( price > recommendedSellPrice && price != ask0 ) ) )
         {
            if ( price <  recommendedSellPrice ) PrintFormat ( "price <  recommendedSellPrice :   price = %5.2f  recommendedSellPrice = %5.2f" , price , recommendedSellPrice );
            if ( price == recommendedSellPrice ) PrintFormat ( "price == recommendedSellPrice :   price = %5.2f  recommendedSellPrice = %5.2f" , price , recommendedSellPrice );
            if ( price >  recommendedSellPrice ) PrintFormat ( "price >  recommendedSellPrice :   price = %5.2f  recommendedSellPrice = %5.2f" , price , recommendedSellPrice );
            PrintFormat ( "%s >>  price = %15.9f  ask0 = %5.2f  ask1 = %5.2f  minAsk = %5.2f recommendedSellPrice = %15.9f" , Symbol() , price , ask0 , ask1 , minAsk , recommendedSellPrice );
            repriceOrder ( ticket , recommendedSellPrice ); 
         }

         //if ( type == ORDER_TYPE_BUY_LIMIT  && ( price < bid0_price || price > bid1_price ) && price != recommendedBuyPrice  ) repriceOrder ( ticket , recommendedBuyPrice  ); 
         //if ( type == ORDER_TYPE_SELL_LIMIT && ( price > ask0_price || price < ask1_price ) && price != recommendedSellPrice ) repriceOrder ( ticket , recommendedSellPrice ); 
      }
   }

   //-----------------------------------------------------------------
   // 9. Place the initial setup (first time only)
   //-----------------------------------------------------------------

   if ( firstBookEvent )
   {
      for ( int i = 0 ; i < N ; i++ ) placeNewOrder ( ORDER_TYPE_BUY_LIMIT  );
      //for ( int i = 0 ; i < N ; i++ ) placeNewOrder ( ORDER_TYPE_SELL_LIMIT );
      firstBookEvent = false;
   }
}

//--------------------------------------------------------------------
// Function placeNewOrder ( orderType ) 
//--------------------------------------------------------------------

bool placeNewOrder ( ENUM_ORDER_TYPE orderType )
{  
   MqlTradeRequest request = {0};
   MqlTradeResult  result  = {0};
   
   double price = ( orderType == ORDER_TYPE_BUY_LIMIT ) ? recommendedBuyPrice : recommendedSellPrice;
 
   if ( price == 0.00 ) return false;
         
   request.action       = TRADE_ACTION_PENDING; // Trade operation type. Can be one of the ENUM_TRADE_REQUEST_ACTIONS enumeration values.
   request.magic        = 19651127;             // Expert Advisor ID (magic number). It allows organizing analytical processing of trade orders. 
   request.symbol       = Symbol();             // Trade symbol 
   request.volume       = V;                    // Requested volume for a deal in lots 
   request.price        = price;                // The price at which the order must be executed.
   request.stoplimit    = 0;                    // StopLimit level, i.e., the price at which the Limit pending order will be placed 
   request.sl           = 0;                    // Stop Loss price in case of unfavorable price movement 
   request.tp           = 0;                    // Take Profit price in case of favorable price movement 
   request.deviation    = 0;                    // Maximal possible deviation from the requested price, in points 
   request.type         = orderType;            // Order type. Can be one of the ENUM_ORDER_TYPE enumeration values. 
   request.type_filling = ORDER_FILLING_RETURN; // Order execution type. Can be one of the enumeration ENUM_ORDER_TYPE_FILLING values. 
   request.type_time    = ORDER_TIME_DAY;       // Order expiration type. Can be one of the enumeration ENUM_ORDER_TYPE_TIME values.
   
   ResetLastError();

   if ( ! OrderSendAsync(request,result) )
   {
      int lastError = GetLastError();
      MqlTradeCheckResult chk;
      bool r = OrderCheck(request,chk);
      PrintFormat ( "%s >> ERROR: function addOrder ( %d , %5.2f ) failed. LastError = %d. RetCode = %d.",
                     Symbol() , EnumToString(orderType) , price , lastError , chk.retcode );
      return false;
   }
   
   PrintFormat ( "%s >> New order %s %4.0f @ %5.2f" , Symbol() , EnumToString(orderType) , V , price );
      
   return true;
}

//--------------------------------------------------------------------
// Function repriceOrder ( ticket , newPrice ) 
//--------------------------------------------------------------------

bool repriceOrder ( ulong ticket , double newPrice )
{   
   MqlTradeRequest request = {0};
   MqlTradeResult  result  = {0};
   
   request.action       = TRADE_ACTION_MODIFY;  // Trade operation type. Can be one of the ENUM_TRADE_REQUEST_ACTIONS enumeration values.
   request.order        = ticket;               // Order ticket. It is used for modifying pending orders.
   request.price        = newPrice;             // The price at which the order must be executed.
   request.stoplimit    = 0;                    // StopLimit level, i.e., the price at which the Limit pending order will be placed 
   request.sl           = 0;                    // Stop Loss price in case of unfavorable price movement 
   request.tp           = 0;                    // Take Profit price in case of favorable price movement 
   request.deviation    = 0;                    // Maximal possible deviation from the requested price, in points 
   request.type_time    = ORDER_TIME_DAY;       // Order expiration type. Can be one of the enumeration ENUM_ORDER_TYPE_TIME values.

   ResetLastError();
    
   if ( ! OrderSendAsync(request,result) )
   {
      int lastError = GetLastError();
      MqlTradeCheckResult chk;
      bool r = OrderCheck(request,chk);
      PrintFormat ( "%s >> ERROR: function repriceOrder ( %d , %5.2f ) failed. LastError = %d. RetCode = %d.",
                     Symbol() , ticket , newPrice , lastError , chk.retcode );
      return false;
   }

   PrintFormat ( "%s >> Order %d was repriced to %5.2f" , Symbol() , ticket , newPrice );
   
   return true;
}

//--------------------------------------------------------------------
// Function removeOrder ( ticket ) 
//--------------------------------------------------------------------

bool removeOrder ( ulong ticket )
{   
   MqlTradeRequest request = {0};
   MqlTradeResult  result  = {0};
   
   request.action    = TRADE_ACTION_REMOVE;  // type of trade operation
   request.order     = ticket;               // order ticket

   ResetLastError();
    
   if ( ! OrderSendAsync(request,result) )
   {
      int lastError = GetLastError();
      MqlTradeCheckResult chk;
      bool r = OrderCheck(request,chk);
      PrintFormat ( "%s >> ERROR: function removeOrder ( %d ) failed. LastError = %d. RetCode = %d.",
                     Symbol() , ticket , lastError , chk.retcode );
      return false;
   }

   PrintFormat ( "%s >> Order %d was removed." , Symbol() , result.order );
      
   return true;
}

//--------------------------------------------------------------------
// Function FatalError ( ticket ) 
//--------------------------------------------------------------------

void FatalError ( string msg )
{
   PrintFormat ( "%s >> "                        , Symbol() , msg );
   PrintFormat ( "%s >> FATAL ERROR: %s"         , Symbol() , msg );
   PrintFormat ( "%s >> "                        , Symbol() , msg );

   PrintFormat ( "%s >> Canceling all pending orders ..."                   , Symbol()       ); 
   PrintFormat ( "%s >> All pending orders were successfully canceled."     , Symbol()       ); 
   PrintFormat ( "%s >> Sending market order for closing open position ..." , Symbol()       ); 
   PrintFormat ( "%s >> Position has been successfully canceled."           , Symbol()       ); 

   PrintFormat ( "%s >> Robot will be shut down ..." , Symbol()       ); 
   ExpertRemove(); 
}

/* BOOOK EM LEILAO - tratar esta situacao:

2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	  0 :  type = BOOK_TYPE_SELL  price = 51.30  volume =      1000
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	  1 :  type = BOOK_TYPE_SELL  price = 51.25  volume =       200
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	  2 :  type = BOOK_TYPE_SELL  price = 51.00  volume =     17500
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	  3 :  type = BOOK_TYPE_SELL  price = 50.99  volume =       300
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	  4 :  type = BOOK_TYPE_SELL  price = 50.88  volume =       300
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	  5 :  type = BOOK_TYPE_SELL  price = 50.00  volume =      1000
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	  6 :  type = BOOK_TYPE_SELL  price = 49.58  volume =       300
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	  7 :  type = BOOK_TYPE_SELL  price = 49.00  volume =       300
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	  8 :  type = BOOK_TYPE_SELL  price = 43.03  volume =       400
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	  9 :  type = BOOK_TYPE_SELL_MARKET  price =  0.00  volume =      1800
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	 10 :  type = BOOK_TYPE_BUY_MARKET  price =  0.00  volume =     10400
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	 11 :  type = BOOK_TYPE_BUY  price = 55.05  volume =       100
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	 12 :  type = BOOK_TYPE_BUY  price = 53.00  volume =      1300
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	 13 :  type = BOOK_TYPE_BUY  price = 52.00  volume =      5100
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	 14 :  type = BOOK_TYPE_BUY  price = 51.50  volume =      1500
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	 15 :  type = BOOK_TYPE_BUY  price = 51.30  volume =      2000
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	 16 :  type = BOOK_TYPE_BUY  price = 51.12  volume =       100
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	 17 :  type = BOOK_TYPE_BUY  price = 50.90  volume =       100
2018.05.23 16:56:54.037	Patinhas_SpreadBot_v5 (UNIP6,M5)	 18 :  type = BOOK_TYPE_BUY  price = 50.61  volume =       100
*/