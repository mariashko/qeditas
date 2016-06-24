(* Copyright (c) 2015-2016 The Qeditas developers *)
(* Distributed under the MIT software license, see the accompanying
   file COPYING or http://www.opensource.org/licenses/mit-license.php. *)

open Big_int;;
open Utils;;
open Ser;;
open Hash;;
open Net;;
open Db;;
open Secp256k1;;
open Signat;;
open Mathdata;;
open Assets;;
open Tx;;
open Ctre;;
open Ctregraft;;
open Block;;
open Blocktree;;
open Setconfig;;

let stkth : Thread.t option ref = ref None;;

let initnetwork () =
  begin
    try
      match !Config.ip with
      | Some(ip) ->
	  let l = openlistener ip !Config.port 5 in
	  Printf.printf "Listening for incoming connections.\n";
	  flush stdout;
	  netlistenerth := Some(Thread.create netlistener l)
      | None ->
	  Printf.printf "Not listening for incoming connections.\nIf you want Qeditas to listen for incoming connections set ip to your ip address\nusing ip=... in qeditas.conf or -ip=... on the command line.\n";
	  flush stdout
    with _ -> ()
  end;
  netseeker ();
  (*** empty placeholder for now ***)
  ();;

type nextstakeinfo = NextStake of (int64 * p2pkhaddr * hashval * int64 * obligation * int64 * big_int) | NoStakeUpTo of int64;;

let nextstakechances : (hashval option,nextstakeinfo) Hashtbl.t = Hashtbl.create 100;;

let compute_recid (r,s) k =
  match smulp k _g with
  | Some(x,y) ->
      if eq_big_int x r then
	if evenp y then 0 else 1
      else
	if evenp y then 2 else 3
  | None -> raise (Failure "bad0");;


let rec hlist_stakingassets blkh alpha hl =
  match hl with
  | HCons((aid,bday,obl,Currency(v)),hr) ->
(*** lock stakingassets ***)
      let ca = coinage blkh bday obl v in
      if gt_big_int ca zero_big_int && not (Hashtbl.mem Commands.unconfirmed_spent_assets aid) then
	Commands.stakingassets := (alpha,aid,bday,obl,v)::!Commands.stakingassets;
(*** unlock stakingassets ***)
      hlist_stakingassets blkh alpha hr
  | HCons(_,hr) -> hlist_stakingassets blkh alpha hr
  | HConsH(h,hr) ->
      begin
	try
	  hlist_stakingassets blkh alpha (HCons(DbAsset.dbget h,hr))
	with Not_found -> ()
      end
  | HHash(h) ->
      begin
	try
	  let (h1,h2) = DbHConsElt.dbget h in
	  match h2 with
	  | Some(h2) -> hlist_stakingassets blkh alpha (HConsH(h1,HHash(h2)))
	  | None -> hlist_stakingassets blkh alpha (HConsH(h1,HNil))
	with Not_found -> ()
      end
  | _ -> ();;

let compute_staking_chances n fromtm totm =
   let i = ref fromtm in
   let BlocktreeNode(par,children,prevblk,thyroot,sigroot,currledgerroot,currtinfo,tmstamp,prevcumulstk,blkhght,validated,blacklisted,succl) = n in
   let (csm1,fsm1,tar1) = currtinfo in
   let c = CHash(currledgerroot) in
   (*** collect assets allowed to stake now ***)
   Commands.stakingassets := [];
   List.iter
     (fun (k,b,(x,y),w,h,alpha) ->
       match ctree_addr true true (hashval_p2pkh_addr h) c None with
       | (Some(hl),_) ->
           hlist_stakingassets blkhght h (nehlist_hlist hl)
       | _ ->
	   ())
     !Commands.walletkeys;
  List.iter
    (fun (alpha,beta,_,_,_,_) ->
      let (p,x4,x3,x2,x1,x0) = alpha in
      let (q,_,_,_,_,_) = beta in
      if not p && not q then (*** only p2pkh can stake ***)
	match ctree_addr true true (payaddr_addr alpha) c None with
	| (Some(hl),_) ->
	    hlist_stakingassets blkhght (x4,x3,x2,x1,x0) (nehlist_hlist hl)
	| _ -> ())
     !Commands.walletendorsements;
  try
    while !i < totm do
      i := Int64.add 1L !i;
      (*** go through assets and check for staking at time !i ***)
      List.iter
	(fun (stkaddr,h,bday,obl,v) ->
	  if gt_big_int (coinage blkhght bday obl v) zero_big_int then
	    begin
	      let mtar = mult_big_int tar1 (coinage blkhght bday obl (incrstake v)) in
	      let ntar = mult_big_int tar1 (coinage blkhght bday obl v) in
(*	      output_string !log ("i := " ^ (Int64.to_string !i) ^ "\nh := " ^ (Hash.hashval_hexstring h) ^ "\nblkhght = " ^ (Int64.to_string blkhght) ^ "\n"); *)
	      let (m3,m2,m1,m0) = csm1 in
(*	      output_string !log ("csm1 := (" ^ (Int64.to_string m3) ^ "," ^ (Int64.to_string m2) ^ "," ^ (Int64.to_string m1) ^ "," ^ (Int64.to_string m0) ^ ")\n");
	      output_string !log ("ntar   := " ^ (string_of_big_int ntar) ^ "\n");
	      output_string !log ("hitval := " ^ (string_of_big_int (hitval !i h csm1)) ^ "\n");
	      flush !log; *)
	      (*** first check if it would be a hit with some storage component: ***)
	      if lt_big_int (hitval !i h csm1) mtar then
		begin (*** if so, then check if it's a hit without some storage component ***)
		  if lt_big_int (hitval !i h csm1) ntar then
		    begin
                      output_string !log ("stake at time " ^ (Int64.to_string !i) ^ " with " ^ (hashval_hexstring h) ^ " in " ^ (Int64.to_string (Int64.sub !i (Int64.of_float (Unix.time()))))  ^ " seconds.\n"); flush !log;
		      let deltm = Int64.to_int32 (Int64.sub !i tmstamp) in
		      let (_,_,tar) = currtinfo in
		      let csnew = cumul_stake prevcumulstk tar deltm in
		      Hashtbl.add nextstakechances prevblk (NextStake(!i,stkaddr,h,bday,obl,v,csnew));
		      raise Exit
		    end
		  else (*** if not, check if there is some storage that will make it a hit [todo] ***)
		    begin
                      ()
		    end
		end
	    end
	)
	!Commands.stakingassets
    done;
    Hashtbl.add nextstakechances prevblk (NoStakeUpTo(totm));
  with
  | Exit -> ()
  | exn ->
      Printf.fprintf stdout "Unexpected Exception in Staking Loop: %s\n" (Printexc.to_string exn); flush stdout


let random_int32_array : int32 array = [| 0l; 0l; 0l; 0l; 0l; 0l; 0l; 0l; 0l; 0l; 0l; 0l; 0l; 0l; 0l; 0l |];;
let random_initialized : bool ref = ref false;;

(*** generate 512 random bits and then use sha256 on them each time we need a new random number ***)
let initialize_random_seed () =
  let r = open_in_bin (if !Config.testnet then "/dev/urandom" else "/dev/random") in
  let v = ref 0l in
  for i = 0 to 15 do
    v := 0l;
    for j = 0 to 3 do
      v := Int32.logor (Int32.shift_left !v 8) (Int32.of_int (input_byte r))
    done;
    random_int32_array.(i) <- !v;
  done;
  random_initialized := true;;

let sha256_random_int32_array () =
  Sha256.sha256init();
  for i = 0 to 15 do
    Sha256.currblock.(i) <- random_int32_array.(i)
  done;
  Sha256.sha256round();
  let (x7,x6,x5,x4,x3,x2,x1,x0) = Sha256.getcurrmd256() in
  for i = 0 to 7 do
    random_int32_array.(i+8) <- random_int32_array.(i)
  done;
  random_int32_array.(0) <- x0;
  random_int32_array.(1) <- x1;
  random_int32_array.(2) <- x2;
  random_int32_array.(3) <- x3;
  random_int32_array.(4) <- x4;
  random_int32_array.(5) <- x5;
  random_int32_array.(6) <- x6;
  random_int32_array.(7) <- x7;;

let rand_256 () =
  if !Config.testnet then
    begin
      if not !random_initialized then initialize_random_seed();
      sha256_random_int32_array();
      Sha256.md256_big_int (Sha256.getcurrmd256())
    end
  else
    begin
      let dr = open_in_bin "/dev/random" in
      let (n,_) = Sha256.sei_md256 seic (dr,None) in
      close_in dr;
      Sha256.md256_big_int n
    end

let rand_bit () =
  if not !random_initialized then initialize_random_seed();
  sha256_random_int32_array();
  random_int32_array.(0) < 0l

let rand_int64 () =
  if not !random_initialized then initialize_random_seed();
  sha256_random_int32_array();
  Int64.logor
    (Int64.of_int32 random_int32_array.(0))
    (Int64.shift_right_logical (Int64.of_int32 random_int32_array.(1)) 32);;

let stakingthread () =
  let sleepuntil = ref (Unix.time()) in
  while true do
    try
      let sleeplen = !sleepuntil -. (Unix.time()) in
      if sleeplen > 1.0 then Unix.sleep (int_of_float sleeplen);
      let best = !bestnode in
      try
	let pbhh = node_prevblockhash best in
	let blkh = node_blockheight best in
        match Hashtbl.find nextstakechances pbhh with
	| NextStake(tm,alpha,aid,bday,obl,v,cs) ->
	    let nw = Unix.time() in
	    if tm > Int64.of_float (nw +. 10.0) then
	      begin (*** wait for a minute and then reevaluate; would be better to sleep until time to publish or until a new best block is found **)
		let tmtopub = Int64.sub tm (Int64.of_float nw) in
		output_string !log ((Int64.to_string tmtopub) ^ " seconds until time to publish staked block\n");
		if tmtopub >= 60L then
		  sleepuntil := nw +. 60.0
		else
		  begin
		    sleepuntil := nw +. Int64.to_float tmtopub;
		  end
	      end
	    else
	      begin (** go ahead and form the block; then publish it at the right time **)
		let prevledgerroot = node_ledgerroot best in
		let (csm0,fsm0,tar0) = node_targetinfo best in
		let pbhtm = node_timestamp best in
		let deltm = Int64.to_int32 (Int64.sub tm pbhtm) in
		let newrandbit = rand_bit() in
		let fsm = stakemod_pushbit newrandbit fsm0 in
		let csm = stakemod_pushbit (stakemod_lastbit fsm0) csm0 in
		let tar = retarget tar0 deltm in
		let alpha2 = p2pkhaddr_addr alpha in
		let obl2 =
		  match obl with
		  | None ->  (* if the staked asset had the default obligation it can be left as the default obligation or locked for some number of blocks to commit to staking; there should be a configurable policy for the node *)
		      if rand_bit() then
			None
		      else
			Some(p2pkhaddr_payaddr alpha,Int64.add blkh (Int64.logand 2048L (rand_int64())),false) (* it is not marked as a reward *)
		  | _ -> obl (* unless it's the default obligation, then the obligation cannot change when staking it *)
		in
		let prevc = Some(CHash(prevledgerroot)) in
		let octree_ctree c =
		  match c with
		  | Some(c) -> c
		  | None -> raise (Failure "tree should not be empty")
		in
		let dync = ref (octree_ctree prevc) in
		let dyntht = ref (lookup_thytree (node_theoryroot best)) in
		let dynsigt = ref (lookup_sigtree (node_signaroot best)) in
		let fees = ref 0L in
		let otherstxs = ref [] in
		Hashtbl.iter
		  (fun h ((tauin,tauout),sg) ->
		    Printf.fprintf !log "Trying to include tx %s\n" (hashval_hexstring h); flush stdout;
		    Printf.printf "trying to include tx %s\n" (hashval_hexstring h); flush stdout; (* delete me *) 
		    try
		      ignore (List.find (fun (_,h) -> h = aid) tauin);
		      Printf.printf "tx spends the staked asset; removing tx from pool\n"; flush stdout; (* delete me *)
		      Commands.remove_from_txpool h
		    with Not_found ->
		      if tx_valid (tauin,tauout) then
			try
			  Printf.printf "txvalid %s\n" (hashval_hexstring h); flush stdout; (* delete me *) 
			  let al = List.map (fun (aid,a) -> a) (ctree_lookup_input_assets true false tauin !dync) in
			  Printf.printf "looked up assets\n"; flush stdout; (* delete me *) 
			  if tx_signatures_valid blkh al ((tauin,tauout),sg) then
			    begin
			      let nfee = ctree_supports_tx true false !dyntht !dynsigt blkh (tauin,tauout) !dync in
			      if nfee > 0L then
				begin
				  Printf.fprintf !log "tx %s has negative fees %Ld; removing from pool\n" (hashval_hexstring h) nfee;
				  flush !log;
				  Commands.remove_from_txpool h;
				end
			      else
				begin
				  Printf.printf "ctree supports tx\n"; flush stdout; (* delete me *) 
				  let c = octree_ctree (tx_octree_trans blkh (tauin,tauout) (Some(!dync))) in
				  otherstxs := (h,((tauin,tauout),sg))::!otherstxs;
				  fees := Int64.sub !fees nfee;
				  dync := c;
				  dyntht := txout_update_ottree tauout !dyntht;
				  dynsigt := txout_update_ostree tauout !dynsigt;
				end
			    end
			  else
			    begin
			      Printf.fprintf !log "tx %s has an invalid signature; removing from pool\n" (hashval_hexstring h);
			      flush !log;
			      Commands.remove_from_txpool h;
			    end
			with exn ->
			  begin
			    Printf.fprintf !log "Exception %s raised while trying to validate tx %s; this may mean the tx is not yet supported so leaving it in the pool\n" (Printexc.to_string exn) (hashval_hexstring h);
			    flush !log;
			  end
		      else
			begin
			  Printf.fprintf !log "tx %s is invalid; removing from pool\n" (hashval_hexstring h);
			  flush !log;
			  Commands.remove_from_txpool h;
			end)
		  Commands.txpool;
		let ostxs = !otherstxs in
		let otherstxs = ref [] in
		List.iter
		  (fun (h,stau) ->
		    Commands.remove_from_txpool h;
		    otherstxs := stau::!otherstxs)
		  ostxs;
		let othertxs = List.map (fun (tau,_) -> tau) !otherstxs in
		let stkoutl = [(alpha2,(obl2,Currency(v)));(alpha2,(Some(p2pkhaddr_payaddr alpha,Int64.add blkh (reward_locktime blkh),true),Currency(Int64.add !fees (rewfn blkh))))] in
		let coinstk : tx = ([(alpha2,aid)],stkoutl) in
		dync := octree_ctree (tx_octree_trans blkh coinstk (Some(!dync)));
		let prevcforblock =
		  match
		    get_txl_supporting_octree (coinstk::othertxs) prevc
		  with
		  | Some(c) -> c
		  | None -> raise (Failure "ctree should not have become empty")
		in
		let (prevcforheader,cgr) = factor_inputs_ctree_cgraft [(alpha2,aid)] prevcforblock in
		let newcr = save_ctree_elements !dync in
(*		    Hashtbl.add recentledgerroots newcr (blkh,newcr); *)
		let bhdnew : blockheaderdata
		    = { prevblockhash = pbhh;
			newtheoryroot = None; (*** leave this as None for now ***)
			newsignaroot = None; (*** leave this as None for now ***)
			newledgerroot = newcr;
			stakeaddr = alpha;
			stakeassetid = aid;
			stored = None;
			timestamp = tm;
			deltatime = deltm;
			tinfo = (csm,fsm,tar);
			prevledger = prevcforheader
		      }
		in
		let bhdnewh = hash_blockheaderdata bhdnew in
		let bhsnew =
		  try
		    let (prvk,b,_,_,_,_) = List.find (fun (_,_,_,_,beta,_) -> beta = alpha) !Commands.walletkeys in
		    let r = rand_256() in
		    let sg : signat = signat_hashval bhdnewh prvk r in
		    { blocksignat = sg;
		      blocksignatrecid = compute_recid sg r;
		      blocksignatfcomp = b;
		      blocksignatendorsement = None
		    }
		  with Not_found ->
		    try
		      let (_,beta,(w,z),recid,fcomp,esg) =
			List.find
			  (fun (alpha2,beta,(w,z),recid,fcomp,esg) ->
			    let (p,x0,x1,x2,x3,x4) = alpha2 in
			    let (q,_,_,_,_,_) = beta in
			    not p && (x0,x1,x2,x3,x4) = alpha && not q)
			  !Commands.walletendorsements
		      in
		      let (_,x0,x1,x2,x3,x4) = beta in
		      let betah = (x0,x1,x2,x3,x4) in
		      let (prvk,b,_,_,_,_) =
			List.find
			  (fun (_,_,_,_,beta2,_) -> beta2 = betah)
			  !Commands.walletkeys in
		      let r = rand_256() in
		      let sg : signat = signat_hashval bhdnewh prvk r in
		      { blocksignat = sg;
			blocksignatrecid = compute_recid sg r;
			blocksignatfcomp = b;
			blocksignatendorsement = Some(betah,recid,fcomp,esg)
		      }
		    with Not_found ->
		      raise (Failure("Was staking for " ^ Cryptocurr.addr_qedaddrstr (hashval_p2pkh_addr alpha) ^ " but have neither the private key nor an appropriate endorsement for it."))
		in
		Printf.fprintf !log "Including %d txs in block\n" (List.length !otherstxs);
		let bhnew = (bhdnew,bhsnew) in
		let bdnew : blockdelta =
		  { stakeoutput = stkoutl;
		    forfeiture = None; (*** leave this as None for now; should check for double signing ***)
		    prevledgergraft = cgr;
		    blockdelta_stxl = !otherstxs
		  }
		in
		begin
		  if valid_blockheader blkh (csm0,fsm0,tar0) bhnew then
		    (Printf.fprintf !log "New block header is valid\n"; flush !log)
		  else
		    (Printf.fprintf !log "New block header is not valid\n"; flush !log; exit 0; raise Not_found);
		  if valid_block None None blkh (csm0,fsm0,tar0) (bhnew,bdnew) then
		    (Printf.fprintf !log "New block is valid\n"; flush stdout)
		  else
		    (Printf.fprintf !log "New block is not valid\n"; flush !log; exit 0; raise Not_found);
		  match pbhh with
		  | None -> if blkh > 1L then (Printf.fprintf !log "No previous block but block height not 1\n"; flush !log; exit 0; raise Not_found)
		  | Some(pbhh) ->
		      if blkh = 1L then (Printf.fprintf !log "Previous block indicated but block height is 1\n"; flush !log; exit 0; raise Not_found);
		      let (pbhd,_) = get_blockheader pbhh in
		      let tmpsucctest bhd1 bhd2 =
			bhd2.timestamp = Int64.add bhd1.timestamp (Int64.of_int32 bhd2.deltatime)
			  &&
			let (csm1,fsm1,tar1) = bhd1.tinfo in
			let (csm2,fsm2,tar2) = bhd2.tinfo in
			stakemod_pushbit (stakemod_lastbit fsm1) csm1 = csm2 (*** new stake modifier is old one shifted with one new bit from the future stake modifier ***)
			  &&
			stakemod_pushbit (stakemod_firstbit fsm2) fsm1 = fsm2 (*** the new bit of the new future stake modifier fsm2 is freely chosen by the staker ***)
			  &&
			eq_big_int tar2 (retarget tar1 bhd2.deltatime)
		      in
		      if tmpsucctest pbhd bhdnew then
			(Printf.fprintf !log "Valid successor block\n"; flush !log)
		      else
			(Printf.fprintf !log "Not a valid successor block\n"; flush !log; exit 0; raise Not_found)
		end;
		let csnew = cumul_stake cs tar bhdnew.deltatime in
		let nw = Unix.time() in
		let tmtopub = Int64.sub tm (Int64.of_float nw) in
		if tmtopub > 1L then Unix.sleep (Int64.to_int tmtopub);
		let publish_new_block () =
		  DbBlockHeader.dbput bhdnewh (bhdnew,bhsnew);
		  DbBlockDelta.dbput bhdnewh bdnew;
		  let newnode =
		    BlocktreeNode(Some(best),ref [],Some(bhdnewh),ottree_hashroot !dyntht,ostree_hashroot !dynsigt,ctree_hashroot !dync,bhdnew.tinfo,tm,csnew,Int64.add 1L blkh,ref Valid,ref false,ref [])
		  in
		  Printf.fprintf !log "block at height %Ld: %s, deltm = %ld, timestamp %Ld, cumul stake %s\n" blkh (hashval_hexstring bhdnewh) bhdnew.deltatime tm (string_of_big_int cs); 
		  record_recent_staker alpha newnode 6;
		  bestnode := newnode;
		  let children_ref = node_children_ref best in
		  children_ref := (bhdnewh,newnode)::!children_ref;
		  (*** missing: code to broadcast to peers ***)
		in
		if pbhh = node_prevblockhash !bestnode then (*** if the bestnode has changed, don't publish it unless the cumulative stake is higher ***)
		  publish_new_block()
		else if csnew > node_cumulstk !bestnode then
		  (Printf.fprintf !log "best != bestnode, but this block better cs\n"; flush stdout;
		  publish_new_block())
	      end
	| NoStakeUpTo(tm) ->
	    let ftm = Int64.add (Int64.of_float (Unix.time())) 36000L in (* reduce to 3600 *)
	    if tm < ftm then
	      compute_staking_chances best tm ftm
	    else
	      Unix.sleep 60
      with Not_found ->
	Unix.sleep 10;
	compute_staking_chances best (node_timestamp best) (Int64.add (Int64.of_float (Unix.time())) 7200L)
    with _ -> ()
  done;;

let sincetime f =
  let snc = Int64.of_float (Unix.time() -. f) in
  if snc >= 172800L then
    (Int64.to_string (Int64.div snc 86400L)) ^ " days"
  else if snc >= 7200L then
    (Int64.to_string (Int64.div snc 7200L)) ^ " hours"
  else if snc >= 120L then
    (Int64.to_string (Int64.div snc 60L)) ^ " minutes"
  else if snc = 1L then
    "1 second"
  else
    (Int64.to_string snc) ^ " seconds";;

let rec parse_command_r l i n =
  if i < n then
    let j = ref i in
    while !j < n && l.[!j] = ' ' do
      incr j
    done;
    let b = Buffer.create 20 in
    while !j < n && not (List.mem l.[!j] [' ';'"']) do
      Buffer.add_char b l.[!j];
      incr j
    done;
    let a = Buffer.contents b in
    let c d = if a = "" then d else a::d in
    if !j < n && l.[!j] = '"' then
      c (parse_command_r_q l (!j+1) n)
    else
      c (parse_command_r l (!j+1) n)
  else
    []
and parse_command_r_q l i n =
  let b = Buffer.create 20 in
  let j = ref i in
  while !j < n && not (l.[!j] = '"') do
    Buffer.add_char b l.[!j];
    incr j
  done;
  if !j < n then
    Buffer.contents b::parse_command_r l (!j+1) n
  else
    raise (Failure("missing quote"))

let parse_command l =
  let ll = parse_command_r l 0 (String.length l) in
  match ll with
  | [] -> raise Exit (*** empty command, silently ignore ***)
  | (c::al) -> (c,al)

let do_command l =
  let (c,al) = parse_command l in
  match c with
  | "exit" ->
      (*** Could call Thread.kill on netth and stkth, but Thread.kill is not always implemented. ***)
      closelog();
      exit 0
  | "getpeerinfo" ->
      remove_dead_conns();
      let ll = List.length !netconns in
      Printf.printf "%d connection%s\n" ll (if ll = 1 then "" else "s");
      List.iter
	(fun (_,(_,_,_,gcs)) ->
	  match !gcs with
	  | Some(cs) ->
	      Printf.printf "%s (%s): %s\n" cs.realaddr cs.addrfrom cs.useragent;
	      let snc = Int64.of_float (Unix.time() -. cs.conntime) in
	      let snc1 = sincetime cs.conntime in
	      let snc2 = sincetime cs.lastmsgtm in
	      Printf.printf "Connected for %s; last message %s ago.\n" snc1 snc2;
	      if cs.handshakestep < 5 then Printf.printf "(Still in handshake phase)\n";
	  | None -> (*** This could happen if a connection died after remove_dead_conns above. ***)
	      Printf.printf "[Dead Connection]\n";
	  )
	!netconns;
      flush stdout
  | "nettime" ->
      let (tm,skew) = network_time() in
      Printf.printf "network time %Ld (median skew of %d)\n" tm skew;
      flush stdout;
  | "printassets" when al = [] -> Commands.printassets()
  | "printassets" -> List.iter (fun h -> Commands.printassets_in_ledger (hexstring_hashval h)) al
  | "printtx" -> List.iter (fun h -> Commands.printtx (hexstring_hashval h)) al
  | "importprivkey" -> List.iter Commands.importprivkey al
  | "importbtcprivkey" -> List.iter Commands.importbtcprivkey al
  | "importwatchaddr" -> List.iter Commands.importwatchaddr al
  | "importwatchbtcaddr" -> List.iter Commands.importwatchbtcaddr al
  | "importendorsement" ->
      begin
	match al with
	| [a;b;s] -> Commands.importendorsement a b s
	| _ -> raise (Failure "importendorsement should be given three arguments: a b s where s is a signature made with the private key for address a endorsing to address b")
      end
  | "btctoqedaddr" -> List.iter Commands.btctoqedaddr al
  | "printasset" ->
      begin
	match al with
	| [h] -> Commands.printasset (hexstring_hashval h)
	| _ -> raise (Failure "printasset <assetid>")
      end
  | "printhconselt" ->
      begin
	match al with
	| [h] -> Commands.printhconselt (hexstring_hashval h)
	| _ -> raise (Failure "printhconselt <hashval>")
      end
  | "printctreeelt" ->
      begin
	match al with
	| [h] -> Commands.printctreeelt (hexstring_hashval h)
	| _ -> raise (Failure "printctreeelt <hashval>")
      end
  | "printctreeinfo" ->
      begin
	match al with
	| [] ->
	    let best = !bestnode in
	    let BlocktreeNode(_,_,_,_,_,currledgerroot,_,_,_,_,_,_,_) = best in
	    Commands.printctreeinfo currledgerroot
	| [h] -> Commands.printctreeinfo (hexstring_hashval h)
	| _ -> raise (Failure "printctreeinfo [ledgerroot]")
      end
  | _ ->
      (Printf.fprintf stdout "Ignoring unknown command: %s\n" c; List.iter (fun a -> Printf.printf "%s\n" a) al; flush stdout);;

let initialize () =
  begin
    datadir_from_command_line(); (*** if -datadir=... is on the command line, then set Config.datadir so we can find the config file ***)
    process_config_file();
    process_config_args(); (*** settings on the command line shadow those in the config file ***)
    if not !Config.testnet then (Printf.printf "Qeditas can only be run on testnet for now. Please give the -testnet command line argument.\n"; exit 0);
    let datadir = if !Config.testnet then (Filename.concat !Config.datadir "testnet") else !Config.datadir in
    let dbdir = Filename.concat datadir "db" in
    dbconfig dbdir; (*** configure the database ***)
    openlog(); (*** Don't open the log until the config vars are set, so if we know whether or not it's testnet. ***)
    if !Config.seed = "" && !Config.lastcheckpoint = "" then
      begin
	raise (Failure "Need either a seed (to validate the genesis block) or a lastcheckpoint (to start later in the blockchain); have neither")
      end;
    if not (!Config.seed = "") then
      begin
	if not (String.length !Config.seed = 40) then raise (Failure "Bad seed");
	try
	  set_genesis_stakemods !Config.seed
	with
	| Invalid_argument(_) ->
	    raise (Failure "Bad seed")
      end;
    if !Config.testnet then
      begin
	max_target := shift_left_big_int unit_big_int 230; (*** make the max_target higher (so difficulty can be easier for testing) ***)
	genesistarget := shift_left_big_int unit_big_int 208; (*** make the genesistarget higher (so difficulty can be easier for testing) ***)
      end;
    initblocktree();
    Printf.printf "Loading wallet\n"; flush stdout;
    Commands.load_wallet();
    Printf.printf "Loading txpool\n"; flush stdout;
    Commands.load_txpool();
    (*** We next compute a nonce for the node to prevent self conns; it doesn't need to be cryptographically secure ***)
    if Sys.file_exists "/dev/urandom" then (* in linux this should give a random enough nonce *)
      let dur = open_in_bin "/dev/urandom" in
      let (n,_) = sei_int64 seic (dur,None) in
      close_in dur;
      this_nodes_nonce := n
    else
      let n = Int64.of_float (Unix.time()) in (*** if /dev/urandom is not available, then just use the current time as the nonce ***)
      this_nodes_nonce := n;
    Printf.fprintf !log "Nonce: %Ld\n" n; flush !log
  end;;

initialize();;
initnetwork();;
if !Config.staking then stkth := Some(Thread.create stakingthread ());;
while true do
  try
    Printf.printf "%s" !Config.prompt; flush stdout;
    let l = read_line() in
    do_command l
  with
  | Exit -> () (*** silently ignore ***)
  | End_of_file -> closelog(); exit 0
  | Failure(x) ->
      Printf.fprintf stdout "Ignoring Uncaught Failure: %s\n" x; flush stdout
  | exn -> (*** unexpected ***)
      Printf.fprintf stdout "Ignoring Uncaught Exception: %s\n" (Printexc.to_string exn); flush stdout
done
