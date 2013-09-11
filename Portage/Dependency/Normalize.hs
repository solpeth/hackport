module Portage.Dependency.Normalize
  (
    normalize_depend
  ) where

import qualified Data.List as L

import Portage.Dependency.Types

mergeDRanges :: DRange -> DRange -> DRange
mergeDRanges _ r@(DExact _) = r
mergeDRanges l@(DExact _) _ = l
mergeDRanges (DRange ll lu) (DRange rl ru) = DRange (max ll rl) (min lu ru)

-- TODO: remove it and switch to 'SatisfiedDepend' instead
empty_dependency :: Dependency
empty_dependency = DependAllOf []

is_empty_dependency :: Dependency -> Bool
is_empty_dependency (DependIfUse _use dep)  =     is_empty_dependency dep
is_empty_dependency (DependAnyOf [])        = True -- because any (const True) == False
is_empty_dependency (DependAnyOf deps)      = any is_empty_dependency deps
is_empty_dependency (DependAllOf deps)      = all is_empty_dependency deps
is_empty_dependency (Atom _pn _dr _dattr)   = False

-- remove one layer of redundancy
normalization_step :: Dependency -> Dependency
normalization_step = combine_atoms
                   . propagate_context
                   . flatten
                   . lift_context
                   . remove_duplicates
                   . remove_empty
                   . sort_deps
                   . combine_use_guards
                   . combine_use_counterguards

remove_empty :: Dependency -> Dependency
remove_empty d =
    case d of
        -- drop full empty nodes
        _ | is_empty_dependency d -> empty_dependency
        -- drop partial empty nodes
        (DependIfUse use dep)     -> DependIfUse use $                                      remove_empty dep
        (DependAllOf deps)        -> DependAllOf $ filter (not . is_empty_dependency) $ map remove_empty deps
        (DependAnyOf deps)        -> DependAnyOf $                                      map remove_empty deps
        -- no change
        (Atom _pn _dr _dattr)     -> d

-- Ideally 'combine_atoms' should handle those as well
remove_duplicates :: Dependency -> Dependency
remove_duplicates d =
    case d of
        (DependIfUse use dep)     -> (DependIfUse use $ remove_duplicates dep)
        (DependAnyOf deps)        -> DependAnyOf $ L.nub $ map remove_duplicates deps
        (DependAllOf deps)        -> DependAllOf $ L.nub $ map remove_duplicates deps
        (Atom _pn _dr _dattr)     -> d

-- TODO: implement flattening (if not done yet in other phases)
--   DependAnyOf [DependAnyOf [something], rest] -> DependAnyOf $ something ++ rest
--   DependAllOf [DependAllOf [something], rest] -> DependAllOf $ something ++ rest
flatten :: Dependency -> Dependency
flatten d =
    case d of
        (DependIfUse use dep)     -> DependIfUse use (flatten dep)
        (DependAnyOf [dep])       -> flatten dep
        (DependAllOf [dep])       -> flatten dep
        (DependAnyOf deps)        -> DependAnyOf $ map flatten deps
        (DependAllOf deps)        -> DependAllOf $ map flatten deps
        (Atom _pn _dr _dattr)     -> d

-- TODO: join atoms with different version constraints
-- DependAllOf [ DRange ">=foo-1" Inf, Drange Zero "<foo-2" ] -> DRange ">=foo-1" "<foo-2"
combine_atoms :: Dependency -> Dependency
combine_atoms d =
    case d of
        (DependIfUse use dep) -> DependIfUse use (combine_atoms dep)
        (DependAllOf deps)    -> DependAllOf $ map combine_atoms $ find_intersections  deps
        (DependAnyOf deps)    -> DependAnyOf $ map combine_atoms $ find_concatenations deps
        (Atom _pn _dr _dattr) -> d

find_intersections :: [Dependency] -> [Dependency]
find_intersections = map merge_depends . L.groupBy is_mergeable
    where is_mergeable :: Dependency -> Dependency -> Bool
          is_mergeable (Atom lpn _ldrange lattr) (Atom rpn _rdrange rattr) = (lpn, lattr) == (rpn, rattr)
          is_mergeable _                         _                         = False

          merge_depends :: [Dependency] -> Dependency
          merge_depends [x] = x
          merge_depends xs = foldl1 merge_pair xs

          merge_pair :: Dependency -> Dependency -> Dependency
          merge_pair (Atom lp ld la) (Atom rp rd ra)
              | lp /= rp = error "merge_pair got different 'PackageName's"
              | la /= ra = error "merge_pair got different 'DAttr's"
              | otherwise = Atom lp (mergeDRanges ld rd) la
          merge_pair l r = error $ unwords ["merge_pair can't merge non-atoms:", show l, show r]

-- TODO
find_concatenations :: [Dependency] -> [Dependency]
find_concatenations = id

-- Eliminate use guarded redundancy:
--   a? ( foo )
--   a? ( bar )
-- gets translated to
--   a? ( foo bar )
combine_use_guards :: Dependency -> Dependency
combine_use_guards d =
    case d of
        (DependIfUse use dep) -> DependIfUse use (combine_use_guards dep)
        (DependAllOf deps)    -> DependAllOf $ map combine_use_guards $ find_use_intersections  deps
        (DependAnyOf deps)    -> DependAnyOf $ map combine_use_guards $ find_use_concatenations deps
        (Atom _pn _dr _dattr) -> d
    where -- TODO
          find_use_concatenations :: [Dependency] -> [Dependency]
          find_use_concatenations = id
          find_use_intersections :: [Dependency] -> [Dependency]
          find_use_intersections = map merge_use_intersections . L.groupBy is_use_mergeable
              where
                    is_use_mergeable :: Dependency -> Dependency -> Bool
                    is_use_mergeable (DependIfUse lu _ld) (DependIfUse ru _rd)
                        | lu == ru       = True
                    is_use_mergeable _ _ = False
                    merge_use_intersections :: [Dependency] -> Dependency
                    merge_use_intersections [x] = x
                    merge_use_intersections ~(DependIfUse u dep : ds) = DependIfUse u $ DependAllOf (dep : [d' | (DependIfUse _u d') <- ds])

-- Eliminate use guarded redundancy:
--   a? ( foo bar )
--   !a? ( foo baz )
-- gets translated to
--   foo
--   a? ( bar )
--   !a? ( baz )
combine_use_counterguards :: Dependency -> Dependency
combine_use_counterguards d =
    case d of
        (DependIfUse use dep) -> DependIfUse use (combine_use_counterguards dep)
        (DependAllOf deps)    -> DependAllOf $ map combine_use_counterguards $ find_use_intersections  deps
        (DependAnyOf deps)    -> DependAnyOf $ map combine_use_counterguards $ find_use_concatenations deps
        (Atom _pn _dr _dattr) -> d
    where -- TODO
          find_use_concatenations :: [Dependency] -> [Dependency]
          find_use_concatenations = id
          find_use_intersections :: [Dependency] -> [Dependency]
          find_use_intersections = concatMap merge_use_intersections . L.groupBy is_counteruse_mergeable
              where
                    is_counteruse_mergeable :: Dependency -> Dependency -> Bool
                    is_counteruse_mergeable (DependIfUse (DUse (lb,lu)) _ld) (DependIfUse (DUse (rb, ru)) _rd)
                        -- lookup 'a?' and '!a?'
                        | lu == ru && lb == not rb = True
                    is_counteruse_mergeable _ _ = False
                    merge_use_intersections :: [Dependency] -> [Dependency]
                    merge_use_intersections [(DependIfUse _lu ld), (DependIfUse _ru rd)]
                        -- very simple special case,
                        -- as we can't look through nested use guards
                        | ld == rd = [ld]
                    merge_use_intersections deps@[(DependIfUse _lu ld), (DependIfUse _ru rd)] =
                       case common_ctx of
                           [] -> deps
                           _  -> [propagate_context $ DependAllOf $ common_ctx ++ deps ]
                        where ld_ctx = lift_context' ld
                              rd_ctx = lift_context' rd
                              common_ctx = ld_ctx `L.intersect` rd_ctx
                    merge_use_intersections x = x

-- Eliminate top-down redundancy:
--   foo/bar
--   u? ( foo/bar
--        bar/baz )
-- gets translated to
--   foo/bar
--   u? ( bar/baz )
propagate_context :: Dependency -> Dependency
propagate_context = propagate_context' []

-- very simple model: pick all sibling-atom deps and add them to context
--                    for downward proparation and remove from 'all_of' part
-- TODO: any-of part can benefit from it by removing useless alternative
-- TODO: analyze different ranges to remove stricter variants like:
--       foo/bar
--       use? ( >=foo/bar-1.0 )
propagate_context' :: [Dependency] -> Dependency -> Dependency
propagate_context' ctx d =
    case d of
        (DependIfUse use dep) -> DependIfUse use (go ctx dep)
        (DependAllOf deps)    -> DependAllOf $ [ go ctx' dep
                                               | dep <- deps
                                               , let atom_deps = [ a
                                                                 | a@(Atom _pn _dp _dattr) <- deps
                                                                 , a /= dep ]
                                               , let ctx' = ctx ++ atom_deps
                                               ]
        (DependAnyOf deps)    -> DependAnyOf $ map (go ctx) deps
        (Atom _pn _dr _dattr) -> case d `elem` ctx of
                                     True  -> empty_dependency
                                     False -> d
  where go c = propagate_context' c

-- Eliminate bottom-up redundancy:
--   || ( ( foo/bar bar/baz )
--        ( foo/bar bar/quux ) )
-- gets translated to
--   foo/bar
--   || ( ( foo/bar bar/baz )
--        ( foo/bar bar/quux ) )
-- It looks like became more gross,
-- but 'propagate_context' phase
-- cleanups it to the following state:
--   foo/bar
--   || ( bar/baz
--        bar/quux )

lift_context :: Dependency -> Dependency
lift_context d =
    case d of
        (DependIfUse _use _dep) -> d
        (DependAllOf deps)      -> DependAllOf $ deps ++ (new_ctx L.\\ deps)
        -- the lift itself
        (DependAnyOf _deps)     -> case L.null new_ctx of
                                       True  -> d -- nothing is shared downwards
                                       False -> propagate_context $ DependAllOf $ new_ctx ++ [d]
        (Atom _pn _dr _dattr)   -> d
  where new_ctx = lift_context' d

-- very simple model: pick all sibling-atom deps and add them to context
--                    for upward proparation and intersect with 'all_of' parts
lift_context' :: Dependency -> [Dependency]
lift_context' d =
    case d of
        (DependIfUse _use _dep) -> []
        (DependAllOf deps)      -> [dep | dep@(Atom _pn _dr _dattr) <- deps]
        (DependAnyOf deps)      -> case map lift_context' deps of
                                       []    -> []
                                       ctxes -> foldl1 L.intersect ctxes
        (Atom _pn _dr _dattr)   -> [d]

-- reorders depends to make them more attractive
-- for other normalization algorithms
-- TODO: add all logic from 'sortDeps' here
sort_deps :: Dependency -> Dependency
sort_deps d =
    case d of
        (DependIfUse lhs (DependIfUse rhs dep))
            | rhs < lhs           -> DependIfUse rhs $ sort_deps $ DependIfUse lhs dep
        (DependIfUse use dep)     -> DependIfUse use $ sort_deps dep
        (DependAnyOf deps)        -> DependAnyOf $ map sort_deps deps
        (DependAllOf deps)        -> DependAllOf $ map sort_deps deps
        (Atom _pn _dr _dattr)     -> d

-- remove various types of redundancy
normalize_depend :: Dependency -> Dependency
normalize_depend d = next_step next_d
    where next_d = normalization_step d
          next_step | d == next_d = id
                    | otherwise   = normalize_depend