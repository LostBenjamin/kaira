module Builder (
	createProgram
) where

import Declarations
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import Parser
import Project
import ProjectTools
import Base
import Codegen
import CodegenTypes
import CodegenTools
import Utils

-- |Emit code that "unpack" tuple into variables
{- FIXME: Following two functions are ugly ancient code, need refactor -}
tupleToVars ::
	[VarDeclaration] ->
	VarSet ->
	String ->
	[NelType] ->
	[NelExpression] ->
	(VarSet -> String -> NelType -> NelExpression -> ([VarDeclaration], [Instruction])) ->
	([VarDeclaration], [Instruction])
tupleToVars vdecls binded var types exprs fn =
	( declarations' ++ declarations, instructions )
	where
		(declarations, instructions) = processExpr varNames types exprs binded 0
		declarations' = fromNelVarDeclarations $ zip varNames types
		varNames = take (length exprs) (newVars' var)
		processExpr :: [String] -> [NelType] -> [NelExpression] -> VarSet -> Int -> ([VarDeclaration], [Instruction])
		processExpr [] _ _ _ _ = ([], [])
		processExpr (v:names) (t:types) (e:exprs) b n =
			let
				(d', i') = processExpr names types exprs (Set.union b (freeVariables e)) (n + 1)
				(d, i) = fn b v t e in
				(d ++ d', [ (ISet (EVar v) (EAt (EInt n) (EVar var))) ] ++ i ++ i')

caContext = TPointer (TRaw "CaContext")

patternCheck :: Project -> [VarDeclaration] -> VarSet -> String -> NelType -> NelExpression -> Instruction -> ([VarDeclaration], [Instruction])
patternCheck project decls binded var (TypeTuple types) (ExprTuple exprs) errEvent =
	tupleToVars decls binded var types exprs (\b v t e -> patternCheck project decls b v t e errEvent)
patternCheck project decls binded var t (ExprVar v) errEvent | not (Set.member v binded) = ([], [ISet (EVar v) (EVar var)])
patternCheck project decls binded var t (ExprVar v) errEvent =
	case List.lookup v decls of
		Just (TData _ _ _ _) -> error "Extern types cannot be compared"
		Just _ -> ([], [(IIf (ECall "!=" [(EVar v), (EVar var)]) errEvent INoop)])
		Nothing -> error "patternCheck: This cannot happend"
patternCheck project decls binded var t x errEvent = ([], [(IIf (ECall "!=" [process x, (EVar var)]) errEvent INoop)])
	where process = processInputExpr project EVar

patternCheckStatement :: Project -> [VarDeclaration] -> VarSet -> String -> NelType -> NelExpression -> Instruction -> Instruction
patternCheckStatement project decls binded var t expr errEvent =
	makeStatement decl instructions
	where
		(decl, instructions) = patternCheck project decls binded var t expr errEvent

placesTuple :: Network -> Type
placesTuple network = TTuple $ map (TArray . fromNelType . placeType) (places network)

processInputExpr :: Project -> (String -> Expression) -> NelExpression -> Expression
processInputExpr project fn (ExprInt x) = EInt x
processInputExpr project fn (ExprString x) = EString x
processInputExpr project fn (ExprVar x) = fn x
processInputExpr project fn (ExprParam x) = EVar $ parameterGlobalName x
processInputExpr project fn (ExprCall "iid" []) = ECall ".iid" [ EVar "ctx" ]
processInputExpr project fn (ExprCall name exprs)
	| isBasicNelFunction name = ECall name [ processInputExpr project fn expr | expr <- exprs ]
	| isUserFunction project name = ECall name [ processInputExpr project fn expr | expr <- exprs ]
processInputExpr project fn (ExprTuple exprs) = ETuple [ processInputExpr project fn expr | expr <- exprs ]
processInputExpr project fn x = error $ "Input expression contains: " ++ show x

{- FIXME: Forbid calling iid() etc -}
processInputExprParamsOnly :: Project -> NelExpression -> Expression
processInputExprParamsOnly = processInputExprConstant

processInputExprConstant :: Project -> NelExpression -> Expression
processInputExprConstant project = processInputExpr project (\x -> error "Variables are not allowed in this expression")

parameterGlobalName :: String -> String
parameterGlobalName x = "__parameter_" ++ x

transitionVarType :: Project -> Transition -> Type
transitionVarType project transition =
	TStruct ("Vars_t" ++ show (transitionId transition))
		(fromNelVarDeclarations $ transitionFreeVariables project transition)

transportType :: Project -> Transition -> [Edge] -> Int -> Type
transportType project transition edges helpId =
	TStruct ("Transport_" ++ show (transitionId transition) ++ "_" ++ show helpId) types
	where
		types = fromNelVarDeclarations $ edgesFreeVariables project edges

processEdge ::  Network -> Edge -> String -> [String] -> [Instruction] -> Instruction
processEdge network (Edge placeId expr _) var restrictions body =
		IForeach var counterVar (EAt (EInt seq) (EVar "places")) (prefix:body)
	where
		counterVar = var ++ "_i"
		seq = placeSeqById network placeId
		t = placeTypeById network placeId
		prefix = if restrictions == [] then INoop else
			IIf (callIfMore "||" [ ECall "==" [(EVar v), (EVar counterVar)] | v <- restrictions ]) IContinue INoop


checkEdges :: Project -> Network -> [VarDeclaration] -> VarSet -> [Edge] -> [Edge] -> Int
			-> Instruction -> [NelExpression] -> Instruction
checkEdges project network decls binded processedEdges [] level okEvent guards = okEvent
{- Variant for normal edges -}
checkEdges project network decls binded processedEdges (edge:rest) level okEvent guards | isNormalEdge edge =
	processEdge network edge var (compRestrictions processedEdges 0) $ [
		patternCheckStatement project decls binded var edgeType expr IContinue ] ++
			map guardCode coveredGuards ++
			[ checkEdges project network decls newVars (edge:processedEdges) rest (level + 1) okEvent uncoveredGuards ]
	where
		newVars = Set.union binded $ freeVariables expr
		(coveredGuards, uncoveredGuards) = List.partition (isCovered newVars) guards
		edgeType = placeTypeByEdge project edge
		processExpr e = processInputExpr project EVar e
		guardCode guard = if guard == ExprTrue then INoop else IIf (ECall "!" [ processExpr guard ]) IContinue INoop
		EdgeExpression expr = edgeInscription edge
		varCounterName level = "c_" ++ show level ++ "_i"
		var = "c_" ++ show level
		compRestrictions :: [Edge] -> Int -> [String]
		compRestrictions [] _ = []
		compRestrictions (e:es) level
			| edgePlaceId edge == edgePlaceId e = (varCounterName level):compRestrictions es (level + 1)
			| otherwise = compRestrictions es (level + 1)

{- Variant for packing edges -}
checkEdges project network decls binded processedEdges (edge:rest) level okEvent guards =
	makeStatement [] [
		IIf (ECall "<" [ ECall "List.size" [ placeExpr ], ECall "+" [ limitExpr, EInt (length edgesWithSamePlace)]])
			operation INoop,
		(checkEdges project network decls binded (edge:processedEdges) rest (level + 1) okEvent guards)
	]
	where
		operation = if any isNormalEdge processedEdges then IContinue else IReturn (EInt 0)
		edgesWithSamePlace = [ e | e <- processedEdges, edgePlaceId e == edgePlaceId edge ]
		EdgePacking name limit = edgeInscription edge
		limitExpr = case limit of
			Just x -> processInputExpr project EVar x
			Nothing -> error "Limit on input edge is not defined"
		placeExpr = EAt (EInt (placeSeqById network (edgePlaceId edge))) (EVar "places")

transitionFunctionName :: Transition -> String
transitionFunctionName transition = "transition_" ++ show (transitionId transition)

{- On edges in & out -}
transitionFreeVariables :: Project -> Transition -> [NelVarDeclaration]
transitionFreeVariables project transition =
	edgesFreeVariables project $ (edgesIn transition) ++ (edgesOut transition)

transitionFreeVariablesIn :: Project-> Transition -> [NelVarDeclaration]
transitionFreeVariablesIn project transition =
	edgesFreeVariables project (edgesIn transition)

transitionFreeVariablesOut :: Project -> Transition -> [NelVarDeclaration]
transitionFreeVariablesOut project transition =
	edgesFreeVariables project (edgesOut transition)

-- |Remove edges that has not place in network
transitionFilterEdges :: Network -> [Edge] -> [Edge]
transitionFilterEdges network edges =
	filter edgeFromNetwork edges
	where edgeFromNetwork edge = List.elem (edgePlaceId edge) (map placeId (places network))

reportFunctionName :: Network -> String
reportFunctionName network = "report_" ++ show (networkId network)

reportFunction :: Project -> Network -> Function
reportFunction project network = Function {
	functionName = reportFunctionName network,
	parameters = [ ("ctx", caContext, ParamNormal),
		("places", TPointer $ (placesTuple network), ParamNormal),
		("out", TPointer $ TRaw "CaOutput", ParamNormal) ],
	declarations = [],
	instructions = header ++ concat (countedMap reportPlace (places network)) ++ concatMap reportTransition (transitions network),
	extraCode = "",
	returnType = TVoid
	}
	where
		header = [
			icall ".set" [ EVar "out", EString "node", ECall ".node" [ EVar "ctx" ] ],
			icall ".set" [ EVar "out", EString "iid", ECall ".iid" [ EVar "ctx" ] ],
			icall ".set" [ EVar "out", EString "network-id", EInt (networkId network) ],
			IIf (ECall "._check_halt_flag" [ EVar "ctx" ])
				(icall ".set" [ EVar "out", EString "running", EString "false" ])
				(icall ".set" [ EVar "out", EString "running", EString "true"])]
		reportPlace i p = [
			icall ".child" [ EVar "out", EString "place" ],
			icall ".set" [ EVar "out", EString "id", EInt (placeId p) ],
			IForeach "x" "x_c" (EAt (EInt i) (EVar "places")) [
				icall ".child" [ EVar "out", EString "token" ],
				icall ".set" [ EVar "out", EString "value", ECall "Base.asString" [ EVar "x" ] ],
				icall ".back" [ EVar "out" ]
			],
			icall ".back" [ EVar "out"]]
		reportTransition t = [
			icall ".child" [ EVar "out", EString "transition" ],
			icall ".set" [ EVar "out", EString "id", EInt (transitionId t) ],
			IIf (ECall (transitionEnableTestFunctionName t) [ EVar "ctx", EVar "places" ])
				(icall ".set" [ EVar "out", EString "enable", EString "true" ])
				(icall ".set" [ EVar "out", EString "enable", EString "false"]),
			icall ".back" [ EVar "out" ]
			]


transitionFunction :: Project -> Network -> Transition -> Function
transitionFunction project network transition = Function {
		functionName = transitionFunctionName transition,
		parameters = [ ("ctx", caContext, ParamNormal), ("places", TPointer $ placesTuple network, ParamNormal)],
		declarations = decls,
		instructions = [instructions, IReturn (EInt 0)],
		extraCode = "",
		returnType = TInt
	}
	where
		decls = fromNelVarDeclarations $ transitionFreeVariablesIn project transition
		instructions = checkEdges project network decls Set.empty [] (edgesIn transition)
			0 (transitionOkEvent project network transition) [ guard transition ]

transitionEnableTestFunctionName :: Transition -> String
transitionEnableTestFunctionName transition = "transition_enable_" ++ show (transitionId transition)

transitionEnableTestFunction :: Project -> Network -> Transition -> Function
transitionEnableTestFunction project network transition = Function {
	functionName = transitionEnableTestFunctionName transition,
	parameters = [ ("ctx", caContext, ParamNormal), ("places", TPointer $ placesTuple network, ParamNormal)],
	declarations = decls,
	instructions = [ instructions, IReturn (EInt 0) ],
	extraCode = "",
	returnType = TInt
	}
	where
		decls = fromNelVarDeclarations $ transitionFreeVariablesIn project transition
		instructions = checkEdges project network decls Set.empty [] (edgesIn transition)
			0 (IReturn $ EInt 1) [ guard transition ]

{-
	Erasing dependancy is added for reason that { List.eraseAt(l, x); List.eraseAt(l, y); } is problem if x < y
-}
transitionOkEvent project network transition = makeStatement [ ("var", transitionVarType project transition) ] body
	where
		body = map erase eraseDependancy ++ packing ++ map setVar decls ++ [ call ] ++ applyResult ++
				(sendInstructions project network transition) ++ [ IReturn (EInt 1) ]
		localOutEdges = filter (Maybe.isNothing . edgeTarget) $ transitionFilterEdges network (edgesOut transition)
		setVar (name, _) = ISet (EAt (EString name) (EVar "var")) (EVar name)
		decls = transitionFreeVariablesIn project transition
		counterName i = "c_" ++ show i ++ "_i"
		placeExprOfEdge edge = EAt (EInt (placeSeqById network (edgePlaceId edge))) (EVar "places")
		erase ((i, edge), dep) = safeErase (placeExprOfEdge edge) (counterName i) (map (counterName . fst) dep)
		eraseDependancy = triangleDependancy (\(i1,e1) (i2,e2) -> edgePlaceId e1 == edgePlaceId e2) (zip [0..] [ e | e <- edgesIn transition, isNormalEdge e ])
		call = icall (workerFunctionName transition) [ EVar "ctx", EVar "var" ]
		applyResult = map addToPlace localOutEdges
		addToPlace edge = case edgeInscription edge of
			EdgeExpression expr -> addToPlaceOne edge expr
			EdgePacking name _ -> addToPlaceMany edge name
		addToPlaceOne edge expr = icall "List.append" [ placeExpr edge, (preprocess expr) ]
		addToPlaceMany edge name = IForeach "token" "token_c" (EAt (EString name) (EVar "var"))
			[ icall "List.append" [ placeExpr edge, EVar "token" ]]
		placeExpr edge = EAt (EInt (placeSeqById network (edgePlaceId edge))) (EVar "places")
		preprocess e = processInputExpr project (\x -> (EAt (EString x) (EVar "var"))) e
		packing = concat [ packingEdge e | e <- edgesIn transition, not (isNormalEdge e) ]
		packingEdge e = let EdgePacking name _ = edgeInscription e in
			[ ISet (EVar name) (placeExprOfEdge e),
			  icall "List.clear" [ placeExprOfEdge e ] ]


sortBySendingPriority :: [Edge] -> [Edge]
sortBySendingPriority edges = List.sortBy sortFn edges
	where
		sortFn x y | isNormalEdge x == isNormalEdge y = EQ
				| isNormalEdge x = GT
				| otherwise = LT

sendInstructions :: Project -> Network -> Transition -> [Instruction]
sendInstructions project network transition =
	[ sendStatement project network (edgeNetwork project edge) transition edge | edge <- sortBySendingPriority foreignEdges ]
	where
		foreignEdges = filter (Maybe.isJust . edgeTarget) (edgesOut transition)
		{- Disabled as premature optimization
		networkAndEdgesAll = concat [ [ (n, e, helpId) | (e, helpId) <- zip (divide edgeTarget (transitionFilterEdges n edges)) [1..] ] | n <- networks project ]
		networkAndEdges = filter (\(_, x, _) -> x /= []) networkAndEdgesAll -}

{- Create code that stores expression into packer -}
packCode :: Expression -> Type -> Expression -> Instruction
packCode packer t expr | canBeDirectlyPacked t =
	makeStatement [ ("data", t) ] [
		ISet (EVar "data") expr,
		icall ".pack" [ packer, EAddr (EVar "data"), exprMemSize t expr ]
	]
packCode packer TString expr = makeStatement [ ("data", TString), ("size", TRaw "size_t") ] [
			ISet (EVar "data") expr,
			ISet (EVar "size") $ ECall ".size" [EVar "data"],
			icall ".pack_size" [ packer, EVar "size" ],
			icall ".pack" [ packer, ECall ".c_str" [ EVar "data" ], EVar "size" ]]
packCode packer (TTuple types) expr =
	makeStatement [] [ packCode packer t (EAt (EInt x) expr) | (x, t) <- zip [0..] types ]
packCode packer (TData name rawType TransportCustom functions) var =
	icall (name ++ "_pack") [ packer, var ]
packCode packer t expr = error "packCode: Type cannot be packed"

unpackCode :: Expression -> Type -> String -> [Instruction]
unpackCode unpacker t var | canBeDirectlyPacked t =
	[ idefineEmpty var t,
		icall ".unpack" [ unpacker, EAddr (EVar var), exprMemSize t undefined ] ]
unpackCode unpacker TString var = [ idefine var TString $ ECall ".unpack_string" [ unpacker ] ]
unpackCode unpacker (TTuple types) var =
	concat [ unpackCode unpacker t name | (name, t) <- vars ] ++
		[ idefine var (TTuple types) (ETuple [ EVar name | (name, t) <- vars ])]
	where vars = [ (var ++ show i, t) | (i, t) <- zip [0..] types ]
unpackCode unpacker (TData name rawType TransportCustom functions) var =
	[ idefine var (TData name rawType TransportCustom functions) (ECall (name ++ "_unpack") [ unpacker ]) ]

unpackCode unpacker t var = error $ "unpackCode: Type cannot be unpacked"

sendStatement :: Project -> Network -> Network -> Transition -> Edge -> Instruction
{- Version for normal edges -}
sendStatement project fromNetwork toNetwork transition edge | isNormalEdge edge =
	makeStatement [] [
		idefine "item" etype (preprocess expr),
		idefine "packer" (TRaw "CaPacker") (ECall "CaPacker" [exprMemSize etype (EVar "item")]),
		packCode packer etype (EVar "item"),
		icall "ca_send" [
			EVar "ctx",
			target,
			dataId,
			packer ]
	]
	where
		etype = fromNelType (edgePlaceType project edge)
		packer = EVar "packer"
		EdgeExpression expr = edgeInscription edge
		dataId = EInt $ edgePlaceId edge
		preprocess e = processInputExpr project (\x -> (EAt (EString x) (EVar "var"))) e
		target =  ECall "+" [ (processedAddress project toNetwork),
			(preprocess . Maybe.fromJust . edgeTarget) edge ]
{- Version for packing edge -}
sendStatement project fromNetwork toNetwork transition edge =
	makeStatement' [] [ ("target", TInt, target) ]
	 [
	IForeach "item" "i" (EAt (EString name) (EVar "var")) [
	makeStatement' [] [ ("packer", TRaw "CaPacker", ECall "CaPacker" [exprMemSize etype (EVar "item")]) ] [
		packCode packer etype (EVar "item"),
		icall "ca_send" [
			EVar "ctx",
			EVar "target",
			dataId,
			packer ]
	]]]
	{-icall "ca_send" [


		ExprVar "ctx",
		ExprVar "target",
		dataId,
		ExprAddr $ ExprVar "data",
		ExprCall "sizeof" [ExprVar (typeString (edgePlaceType project edge))]
	]]]-}
	where
		packer = EVar "packer"
		etype = fromNelType (edgePlaceType project edge)
		EdgePacking name limit = edgeInscription edge
		dataId = EInt $ edgePlaceId edge
		preprocess e = processInputExpr project (\x -> (EAt (EString x) (EVar "var"))) e
		target =  ECall "+" [ (processedAddress project toNetwork),
			(preprocess . Maybe.fromJust . edgeTarget) edge ]

{- Disables as premature optimization
sendStatement :: Project -> Network -> Network -> Transition -> [Edge] -> Int -> Instruction
sendStatement project fromNetwork toNetwork transition edges helpId =
	IStatement [ ("transport", transportType project transition edges helpId) ] ((map addToTransport filteredEdges) ++ [callSend])
	where
		filteredEdges = List.nubBy (\x y -> edgeExpr x == edgeExpr y) edges
		addToTransport edge = ISet (ExprAt (varStrFromEdge edge) (ExprVar "transport")) (ExprAt (varStrFromEdge edge) (ExprVar "var"))
		varStrFromEdge edge = let ExprVar x = edgeExpr edge in ExprString x {- Ugly hack, need flexibile code -}
		callSend = IExpr (ExprCall "ca_send" [ target, dataId, ExprAddr (ExprVar "transport"), ExprCall "sizeof" [ExprVar "transport"]])
		dataId = ExprInt $ (transitionId transition) * 1000 + helpId {- cheap little hack -}
		target = ExprCall "+" [ ExprInt (address toNetwork), (Maybe.fromJust . edgeTarget . head) edges ]
-}


recvFunctionName :: Network -> String
recvFunctionName network = "recv_callback" ++ show (networkId network)

allTransitions :: Project -> [Transition]
allTransitions project = concatMap transitions (networks project)

{- !!
   In fact this is next little cheap hack, dataId of packet is directly place,
   there shoule be more grupped sending
-}
recvFunction :: Project -> Network -> Function
recvFunction project network = Function {
	functionName = recvFunctionName network,
	parameters = [ ("places", TPointer (placesTuple network), ParamNormal),
		("data_id", TRaw "int", ParamNormal),
		("data", TRaw "void*", ParamNormal),
		("data_size", TRaw "int", ParamNormal) ],
	declarations = [],
	extraCode = [],
	returnType = TVoid,
	instructions = [ makeStatement' [] [ ("unpacker", TRaw "CaUnpacker", (ECall "CaUnpacker" [ EVar "data" ])) ]
		[ recvStatement network place | place <- (places network), isTransportable (placeType place) ]]
}

recvStatement :: Network -> Place -> Instruction
recvStatement network place =
	IIf condition ifStatement INoop
	where
		condition = ECall "==" [ EVar "data_id", EInt (placeId place) ]
		ifStatement = makeStatement []
			(unpackCode (EVar "unpacker") (fromNelType (placeType place)) "item" ++
			[ IExpr (ECall "List.append"
				[ EAt (EInt (placeSeq network place)) (EVar "places"),  (EVar "item") ])])

{- This is not good aproach if there are more vars, but it now works -}
safeErase :: Expression -> String -> [String] -> Instruction
safeErase list v [] = icall "List.eraseAt" [ list, EVar v ]
safeErase list v deps = makeStatement [ ("tmp", TInt) ] $ [ ISet (EVar "tmp") (EVar v) ] ++ erase deps
	where
		erase [] = [ safeErase list "tmp" [] ]
		erase (d:ds) =
			(IIf (ECall "<" [ EVar d, EVar v ]) (ISet (EVar "tmp") (ECall "-" [ EVar "tmp", EInt 1 ])) INoop):(erase ds)

workerFunctionName :: Transition -> String
workerFunctionName transition = "worker_" ++ show (transitionId transition)

workerFunction :: Project -> Transition -> Function
workerFunction project transition = Function {
	functionName = workerFunctionName transition,
	parameters = [ ("ctx", caContext, ParamNormal), ("var", transitionVarType project transition, ParamNormal) ],
	declarations = [],
	instructions = [],
	extraCode = transitionCode transition,
	returnType = TVoid
}

initFunctionName :: Place -> String
initFunctionName place = "init_place_" ++ show (placeId place)

initFunction :: Place -> Function
initFunction place = Function {
		functionName = initFunctionName place,
		parameters = [ ("ctx", caContext, ParamNormal),
			("place", TPointer $ TArray (fromNelType (placeType place)), ParamNormal)],
		declarations = [],
		instructions = [],
		extraCode = placeInitCode place,
		returnType = TVoid
	}

placesWithInit :: Network -> [Place]
placesWithInit network = [ p | p <- places network, placeInitCode p /= "" ]

startFunctionName :: Network -> String
startFunctionName network = "init_network_" ++ show (networkId network)

startFunction :: Project -> Network -> Function
startFunction project network = Function {
	functionName = startFunctionName network,
	parameters = [ ("ctx", caContext, ParamNormal) ],
	declarations = [ ("places", TPointer $ placesTuple network) ],
	instructions = [ allocPlaces, initCtx ] ++ registerTransitions ++ eventNodeInit ++ initPlaces,
	extraCode = "",
	returnType = TVoid
	} where
	{-	allocPlaces = ISet (ExprVar "places") $ ExprCall "new" [ ExprCall (typeString (TPointer $ placesTuple network))  [] ]-}
		allocPlaces = IInline $ "places = new " ++ (typeSafeString (placesTuple network)) ++ "();"
		nodeExpr = ECall ".node" [ EVar "ctx" ]
		initCtx = icall "._init" [
			(EVar "ctx"), (ECall "-" [nodeExpr, (processedAddress project network)]),
			(processedInstances project network), EVar "(void*) places",
			{- This is ugly hack -} EVar ("(RecvFn*)" ++ (recvFunctionName network)),  EVar ("(ReportFn*)" ++ reportFunctionName network) ]
		ps p = placeSeq network p
		initPlaces = (map initPlaceFromExpr (places network)) ++ (map callInitPlace (placesWithInit network))
		initPlace p = [	initPlaceFromExpr p, callInitPlace p ]
		registerTransitions = [ icall "._register_transition" [
			EVar "ctx", EInt (transitionId t), EVar ("(TransitionFn*)" ++ transitionFunctionName t) ] | t <- transitions network ]
		placeVar p = EAt (EInt (ps p)) (EVar "places")
		callInitPlace p =
			 icall (initFunctionName p) [ EVar "ctx", EAddr (placeVar p) ]
		eventNodeInit = if hasEvent project "node_init" then [ icall "node_init" [ EVar "ctx" ] ] else []
		initPlaceFromExpr p =
			case placeInitExpr p of
				Nothing -> INoop
				Just x -> icall "List.append" [ placeVar p, processInputExprConstant project x ]
	{-	startCode = \n\t(ctx, &places, tf, (RecvFn*) " ++ recvFunctionName network ++ ");"-}

createNetworkFunctions :: Project -> Network -> [Function]
createNetworkFunctions project network =
	workerF ++ transitionF ++ transitionTestF ++ reportF ++ initF ++ [ recvFunction project network, startFunction project network ]
	where
		transitionF = [ transitionFunction project network t | t <- transitions network ]
		transitionTestF = [ transitionEnableTestFunction project network t | t <- transitions network ]
		initF = map initFunction (placesWithInit network)
		reportF = [ reportFunction project network ]
		workerF =  [ workerFunction project t | t <- transitions network ] {- workerFunction -}

instancesCount :: Project -> Expression
instancesCount project = ECall "+" $ map (processedInstances project) (networks project)

createMainFunction :: Project -> Function
createMainFunction project = Function {
	functionName = "main",
	parameters = [ ("argc", TRaw "int", ParamNormal), ("argv", (TPointer . TPointer . TRaw) "char", ParamNormal) ],
	declarations = [ ("nodes", TInt) ],
	instructions = parseArgs ++ [ i1, i2 ],
	extraCode = [],
	returnType = TInt
} where
	i1 = ISet (EVar "nodes") (instancesCount project)
	i2 = IInline "ca_main(nodes, main_init);"
	parameters = projectParameters project
	parseArgs = [
		IInline $ "const char *p_names[] = {" ++ addDelimiter "," [ "\"" ++ parameterName p ++ "\"" | p <- parameters ] ++ "};",
		IInline $ "const char *p_descs[] = {" ++ addDelimiter "," [ "\"" ++ parameterDescription p ++ "\"" | p <- parameters ] ++ "};",
		IInline $ "int *p_data[] = {" ++ addDelimiter "," [ "&" ++ (parameterGlobalName . parameterName) p | p <- parameters ] ++ "};",
		icall "ca_parse_args" [ EVar "argc", EVar "argv", EInt (length parameters), EVar "p_names", EVar "p_data", EVar "p_descs" ]
	 ]

processedInstances :: Project -> Network -> Expression
processedInstances project = (processInputExprParamsOnly project) . instances

processedAddress :: Project -> Network -> Expression
processedAddress project = (processInputExprParamsOnly project) . address

createMainInitFunction :: Project -> Function
createMainInitFunction project = Function {
	functionName = "main_init",
	parameters = [("ctx", caContext, ParamNormal)],
	declarations = [],
	instructions = startNetworks,
	extraCode = [],
	returnType = TVoid
	}
	where
		node = ECall ".node" [ EVar "ctx" ]
		startNetworks = map startNetwork (networks project)
		test1 n = ECall ">=" [ node, processedAddress project n]
		test2 n = ECall "<" [ node, ECall "+" [processedInstances project n, processedAddress project n]]
		startI n = icall (startFunctionName n) [ EVar "ctx" ]
		startNetwork n = IIf (ECall "&&" [ test1 n, test2 n ]) (startI n) INoop


functionWithCode :: String -> Type -> [ParamDeclaration] -> String -> Function
functionWithCode name returnType params code = Function {
	functionName = name,
	parameters = params,
	declarations = [],
	instructions = [],
	extraCode = code,
	returnType = returnType
}
knownTypeFunctions :: [(String, String -> (Type, [ParamDeclaration]))]
knownTypeFunctions = [
	("getstring", \raw -> (TRaw "std::string", [ ("obj", TRaw $ raw ++ "&", ParamNormal) ])),
	("getsize", \raw -> (TRaw "size_t", [ ("obj", TRaw $ raw ++ "&", ParamNormal) ])),
	("pack", \raw -> (TVoid, [ ("packer", TRaw "CaPacker &", ParamNormal), ("obj", TRaw $ raw ++ "&", ParamNormal) ])),
	("unpack", \raw -> (TRaw raw, [ ("unpacker", TRaw "CaUnpacker &", ParamNormal) ])) ]

typeFunctions :: Type -> [Function]
typeFunctions (TData typeName rawType transportMode ((fname, code):rest)) =
	(functionWithCode (typeName ++ "_" ++ fname) returnType params code)
		: typeFunctions (TData typeName rawType transportMode rest)
	where (returnType, params) = case List.lookup fname knownTypeFunctions of
		Just x -> x rawType
		Nothing -> error $ "typeFunctions: Unknown function " ++ fname
typeFunctions _ = []

eventTable :: [ (String, (Type, [ParamDeclaration])) ]
eventTable = [
	("node_init", (TVoid, [("ctx", caContext, ParamNormal)])),
	("node_quit", (TVoid, [("ctx", caContext, ParamNormal)]))]

createEventFunction :: Event -> Function
createEventFunction event =
	functionWithCode (eventName event) returnType params (eventCode event)
	where (returnType, params) = case List.lookup (eventName event) eventTable of
		Just x -> x
		Nothing -> error $ "createEventFunction: Unknown event " ++ (eventName event)

parameterAccessFunction :: Parameter -> Function
parameterAccessFunction parameter = Function {
	functionName = "parameter_" ++ parameterName parameter,
	parameters = [],
	declarations = [],
	instructions = [ (IReturn . EVar . parameterGlobalName . parameterName) parameter ],
	extraCode = "",
	returnType = fromNelType $ parameterType parameter
}

createUserFunction :: UserFunction -> Function
createUserFunction ufunction =
	functionWithCode (ufunctionName ufunction)
		(fromNelType (ufunctionReturnType ufunction))
		(paramFromVar ParamConst (fromNelVarDeclarations (ufunctionParameters ufunction)))
		(ufunctionCode ufunction)

createProgram :: Project -> String
createProgram project =
	emitProgram prologue globals $ typeF ++ paramF ++ eventsF ++ userF ++ netF ++ [mainInitF, mainF]
	where
		globals = [ (parameterGlobalName $ parameterName p, fromNelType $ parameterType p) | p <- projectParameters project ]
		typeF = concatMap typeFunctions (map fromNelType $ Map.elems (typeTable project))
		netF = concat [ createNetworkFunctions project n | n <- networks project ]
		eventsF = map createEventFunction (events project)
		userF = map createUserFunction (userFunctions project)
		mainInitF = createMainInitFunction project
		mainF = createMainFunction project
		paramF = map parameterAccessFunction (projectParameters project)
		prologue = "#include <stdio.h>\n#include <stdlib.h>\n#include <vector>\n#include <cailie.h>\n\n#include \"head.cpp\"\n\n"

test = readFile "../out/project.xml" >>= return . createProgram . projectFromXml >>= writeFile "../out/project.cpp"
test2 = readFile "../out/project.xml" >>= return . projectFromXml
