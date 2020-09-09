#
#
#           The Nim Compiler
#        (c) Copyright 2020 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## New styled concepts for Nim. See https://github.com/nim-lang/RFCs/issues/168
## for details. Note this is a first implementation and only the "Concept matching"
## section has been implemented.

import ast, astalgo, semdata, lookups, lineinfos, idents, msgs, renderer,
  types, intsets

const
  logBindings = false

proc declareSelf(c: PContext; info: TLineInfo) =
  let ow = getCurrOwner(c)
  let s = newSym(skType, getIdent(c.cache, "Self"), ow, info)
  s.typ = newType(tyTypeDesc, ow)
  s.typ.flags.incl {tfUnresolved, tfPacked}
  s.typ.add newType(tyEmpty, ow)
  addDecl(c, s, info)

proc isSelf*(t: PType): bool {.inline.} =
  t.kind == tyTypeDesc and tfPacked in t.flags

proc semConceptDecl(c: PContext; n: PNode): PNode =
  case n.kind
  of nkStmtList, nkStmtListExpr:
    result = shallowCopy(n)
    for i in 0..<n.len:
      result[i] = semConceptDecl(c, n[i])
  of nkProcDef..nkIteratorDef, nkFuncDef:
    result = c.semExpr(c, n, {efWantStmt})
  of nkTypeClassTy:
    result = shallowCopy(n)
    for i in 0..<n.len-1:
      result[i] = n[i]
    result[^1] = semConceptDecl(c, n[^1])
  else:
    localError(c.config, n.info, "unexpected construct in the new-styled concept " & renderTree(n))
    result = n

proc semConceptDeclaration*(c: PContext; n: PNode): PNode =
  assert n.kind == nkTypeClassTy
  inc c.inConceptDecl
  openScope(c)
  declareSelf(c, n.info)
  result = semConceptDecl(c, n)
  rawCloseScope(c)
  dec c.inConceptDecl

type
  MatchCon = object
    inferred: seq[(PType, PType)]
    marker: IntSet
    potentialImplementation: PType
    magic: TMagic  # mArrGet and mArrPut is wrong in system.nim and
                   # cannot be fixed that easily.
                   # Thus we special case it here.

proc existingBinding(m: MatchCon; key: PType): PType =
  for i in 0..<m.inferred.len:
    if m.inferred[i][0] == key: return m.inferred[i][1]
  return nil

proc conceptMatchNode(c: PContext; n: PNode; m: var MatchCon): bool

proc matchType(c: PContext; f, a: PType; m: var MatchCon): bool =
  const
    ignorableForArgType = {tyVar, tySink, tyLent, tyOwned, tyGenericInst, tyAlias, tyInferred}
  case f.kind
  of tyAlias:
    result = matchType(c, f.lastSon, a, m)
  of tyTypeDesc:
    if isSelf(f):
      #let oldLen = m.inferred.len
      result = matchType(c, a, m.potentialImplementation, m)
      #echo "self is? ", result, " ", a.kind, " ", a, " ", m.potentialImplementation, " ", m.potentialImplementation.kind
      #m.inferred.setLen oldLen
      #echo "A for ", result, " to ", typeToString(a), " to ", typeToString(m.potentialImplementation)
    else:
      if a.kind == tyTypeDesc and f.len == a.len:
        for i in 0..<a.len:
          if not matchType(c, f[i], a[i], m): return false
        return true

  of tyGenericInvocation:
    if a.kind == tyGenericInst and a[0].kind == tyGenericBody:
      if sameType(f[0], a[0]) and f.len == a.len-1:
        for i in 1 ..< f.len:
          if not matchType(c, f[i], a[i], m): return false
        return true
  of tyGenericParam:
    let ak = a.skipTypes({tyVar, tySink, tyLent, tyOwned})
    if ak.kind in {tyTypeDesc, tyStatic} and not isSelf(ak):
      result = false
    else:
      let old = existingBinding(m, f)
      if old == nil:
        if f.len > 0 and f[0].kind != tyNone:
          # also check the generic's constraints:
          let oldLen = m.inferred.len
          result = matchType(c, f[0], a, m)
          m.inferred.setLen oldLen
          if result:
            when logBindings: echo "A adding ", f, " ", ak
            m.inferred.add((f, ak))
        elif m.magic == mArrGet and ak.kind in {tyArray, tyOpenArray, tySequence, tyVarargs, tyCString, tyString}:
          when logBindings: echo "B adding ", f, " ", lastSon ak
          m.inferred.add((f, lastSon ak))
          result = true
        else:
          when logBindings: echo "C adding ", f, " ", ak
          m.inferred.add((f, ak))
          #echo "binding ", typeToString(ak), " to ", typeToString(f)
          result = true
      elif not m.marker.containsOrIncl(old.id):
        result = matchType(c, old, ak, m)
        if m.magic == mArrPut and ak.kind == tyGenericParam:
          result = true
    #echo "B for ", result, " to ", typeToString(a), " to ", typeToString(m.potentialImplementation)

  of tyVar, tySink, tyLent, tyOwned:
    # modifiers in the concept must be there in the actual implementation
    # too but not vice versa.
    if a.kind == f.kind:
      result = matchType(c, f.sons[0], a.sons[0], m)
    elif m.magic == mArrPut:
      result = matchType(c, f.sons[0], a, m)
    else:
      result = false
  of tyEnum, tyObject, tyDistinct:
    result = sameType(f, a)
  of tyEmpty, tyString, tyCString, tyPointer, tyNil, tyUntyped, tyTyped, tyVoid:
    result = a.skipTypes(ignorableForArgType).kind == f.kind
  of tyBool, tyChar, tyInt..tyUInt64:
    let ak = a.skipTypes(ignorableForArgType)
    result = ak.kind == f.kind or ak.kind == tyOrdinal or
       (ak.kind == tyGenericParam and ak.len > 0 and ak[0].kind == tyOrdinal)
  of tyConcept:
    let oldLen = m.inferred.len
    let oldPotentialImplementation = m.potentialImplementation
    m.potentialImplementation = a
    result = conceptMatchNode(c, f.n.lastSon, m)
    m.potentialImplementation = oldPotentialImplementation
    if not result:
      m.inferred.setLen oldLen
  of tyArray, tyTuple, tyVarargs, tyOpenArray, tyRange, tySequence, tyRef, tyPtr,
     tyGenericInst:
    let ak = a.skipTypes(ignorableForArgType - {f.kind})
    if ak.kind == f.kind and f.len == ak.len:
      for i in 0..<ak.len:
        if not matchType(c, f[i], ak[i], m): return false
      return true
  of tyOr:
    let oldLen = m.inferred.len
    if a.kind == tyOr:
      # say the concept requires 'int|float|string' if the potentialImplementation
      # says 'int|string' that is good enough.
      var covered = 0
      for i in 0..<f.len:
        for j in 0..<a.len:
          let oldLenB = m.inferred.len
          let r = matchType(c, f[i], a[j], m)
          if r:
            inc covered
            break
          m.inferred.setLen oldLenB

      result = covered >= a.len
      if not result:
        m.inferred.setLen oldLen
    else:
      for i in 0..<f.len:
        result = matchType(c, f[i], a, m)
        if result: break # and remember the binding!
        m.inferred.setLen oldLen
  of tyNot:
    if a.kind == tyNot:
      result = matchType(c, f[0], a[0], m)
    else:
      let oldLen = m.inferred.len
      result = not matchType(c, f[0], a, m)
      m.inferred.setLen oldLen
  of tyAnything:
    result = true
  of tyOrdinal:
    result = isOrdinalType(a, allowEnumWithHoles = false) or a.kind == tyGenericParam
  else:
    result = false

proc matchReturnType(c: PContext; f, a: PType; m: var MatchCon): bool =
  if f.isEmptyType:
    result = a.isEmptyType
  elif a == nil:
    result = false
  else:
    result = matchType(c, f, a, m)

proc matchSym(c: PContext; candidate: PSym, n: PNode; m: var MatchCon): bool =
  # watch out: only add bindings after a completely successful match.
  let oldLen = m.inferred.len

  let can = candidate.typ.n
  let con = n[0].sym.typ.n

  if can.len < con.len:
    # too few arguments, cannot be a match:
    return false

  let common = min(can.len, con.len)
  for i in 1 ..< common:
    if not matchType(c, con[i].typ, can[i].typ, m):
      m.inferred.setLen oldLen
      return false

  if not matchReturnType(c, n[0].sym.typ.sons[0], candidate.typ.sons[0], m):
    m.inferred.setLen oldLen
    return false

  # all other parameters have to be optional parameters:
  for i in common ..< can.len:
    assert can[i].kind == nkSym
    if can[i].sym.ast == nil:
      # has too many arguments one of which is not optional:
      m.inferred.setLen oldLen
      return false

  return true

proc matchSyms(c: PContext, n: PNode; kinds: set[TSymKind]; m: var MatchCon): bool =
  let name = n[namePos].sym.name
  for scope in walkScopes(c.currentScope):
    var ti: TIdentIter
    var candidate = initIdentIter(ti, scope.symbols, name)
    while candidate != nil:
      if candidate.kind in kinds:
        #echo "considering ", typeToString(candidate.typ), " ", candidate.magic
        m.magic = candidate.magic
        if matchSym(c, candidate, n, m): return true
      candidate = nextIdentIter(ti, scope.symbols)
  result = false

proc conceptMatchNode(c: PContext; n: PNode; m: var MatchCon): bool =
  case n.kind
  of nkStmtList, nkStmtListExpr:
    for i in 0..<n.len:
      if not conceptMatchNode(c, n[i], m):
        return false
    return true
  of nkProcDef, nkFuncDef:
    # procs match any of: proc, template, macro, func, method, converter.
    # The others are more specific.
    # XXX: Enforce .noSideEffect for 'nkFuncDef'? But then what are the use cases...
    const filter = {skProc, skTemplate, skMacro, skFunc, skMethod, skConverter}
    result = matchSyms(c, n, filter, m)
  of nkTemplateDef:
    result = matchSyms(c, n, {skTemplate}, m)
  of nkMacroDef:
    result = matchSyms(c, n, {skMacro}, m)
  of nkConverterDef:
    result = matchSyms(c, n, {skConverter}, m)
  of nkMethodDef:
    result = matchSyms(c, n, {skMethod}, m)
  of nkIteratorDef:
    result = matchSyms(c, n, {skIterator}, m)
  else:
    # error was reported earlier.
    result = false

proc conceptMatch*(c: PContext; concpt, arg: PType; bindings: var TIdTable; invocation: PType): bool =
  var m = MatchCon(inferred: @[], potentialImplementation: arg)
  result = conceptMatchNode(c, concpt.n.lastSon, m)
  if result:
    for (a, b) in m.inferred:
      if b.kind == tyGenericParam:
        var dest = b
        while true:
          dest = existingBinding(m, dest)
          if dest == nil or dest.kind != tyGenericParam: break
        if dest != nil:
          bindings.idTablePut(a, dest)
          when logBindings: echo "A bind ", a, " ", dest
      else:
        bindings.idTablePut(a, b)
        when logBindings: echo "B bind ", a, " ", b
    # we have a match, so bind 'arg' itself to 'concpt':
    bindings.idTablePut(concpt, arg)
    # invocation != nil means we have a non-atomic concept:
    if invocation != nil and arg.kind == tyGenericInst and invocation.len == arg.len-1:
      # bind even more generic parameters
      assert invocation.kind == tyGenericInvocation
      for i in 1 ..< invocation.len:
        bindings.idTablePut(invocation[i], arg[i])