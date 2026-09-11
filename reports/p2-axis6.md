## Scope

This is Yjs-only evidence from the QuickJS probe. It does not assert Yrs parity and does not reopen runtime adoption.

# P2 axis 6 measurement report

- Runtime: `yjs-quickjs`
- Capabilities: decodeUpdate, readStateVector, enumerateFormatMarkers, countPendingStructs, readUndoStackItems

| Scenario | Targets | Outcome | Evidence |
|---|---|---|---|
| S6.1 `same-attribute-different-values-same-range` | ticket 25 formatting half — same attribute, different values, same range; compare both arrival orders and record whether the winner is source-only | pass | forward=[{"insert":"abcde","attributes":{"bold":false}},{"insert":"fgh"}], reversed=[{"insert":"abcde","attributes":{"bold":false}},{"insert":"fgh"}]; the observed winner is a Yjs control-group result, not a server-order guarantee |
| S6.2 `overlapping-but-not-identical-ranges` | ticket 25 formatting half — A formats [0,5), B formats [3,8); observe the overlap [3,5) and both arrival orders | pass | forward=[{"insert":"abc","attributes":{"bold":true}},{"insert":"de","attributes":{"bold":false}},{"insert":"fgh"}], reversed=[{"insert":"abc","attributes":{"bold":true}},{"insert":"de","attributes":{"bold":false}},{"insert":"fgh"}]; overlap is represented by Y.Text delta chunks |
| S6.3 `insert-inside-formatted-range` | ticket 25 formatting half — determine whether a character inserted inside a formatted range inherits the surrounding mark | pass | delta=[{"insert":"a"},{"insert":"bXcd","attributes":{"bold":true}},{"insert":"efgh"}]; inserted X inherits bold=true |
| S6.4 `insert-at-boundary-of-formatted-range` | ticket 25 formatting half — compare insertion at the left and right boundaries of a formatted range against Promeo Sticky Run anchors | pass | left boundary=[{"insert":"aL"},{"insert":"bcd","attributes":{"bold":true}},{"insert":"efgh"}], right boundary=[{"insert":"a"},{"insert":"bcdR","attributes":{"bold":true}},{"insert":"efgh"}] |
| S6.5 `format-a-range-the-other-deleted` | ticket 25 formatting half — formatting applied to a range another participant deletes concurrently | pass | forward=[{"insert":"a"},{"insert":"b","attributes":{"bold":true}},{"insert":"efgh"}], reversed=[{"insert":"a"},{"insert":"b","attributes":{"bold":true}},{"insert":"efgh"}] |
| S6.6 `concurrent-format-and-text-edit-same-range` | ticket 23 formatting differential paths — format and text edit overlap on the same range | pass | forward=[{"insert":"a"},{"insert":"bcef","attributes":{"bold":true}},{"insert":"gh"}], reversed=[{"insert":"a"},{"insert":"bcef","attributes":{"bold":true}},{"insert":"gh"}] |
| S6.7 `format-marker-growth-under-repeated-toggle` | ticket 25 formatting half — repeated format toggles; measure encoded size and ContentFormat structs separately from adoption | pass | 20 toggles: first=159B/2 ContentFormat, last=311B/3 ContentFormat; growth is reported as a measurement |

## Traces

### S6.1

- both writers format the same range differently
-   -> forward=[{"insert":"abcde","attributes":{"bold":false}},{"insert":"fgh"}], reversed=[{"insert":"abcde","attributes":{"bold":false}},{"insert":"fgh"}]

### S6.2

- writers format overlapping ranges
-   -> forward=[{"insert":"abc","attributes":{"bold":true}},{"insert":"de","attributes":{"bold":false}},{"insert":"fgh"}], reversed=[{"insert":"abc","attributes":{"bold":true}},{"insert":"de","attributes":{"bold":false}},{"insert":"fgh"}]

### S6.3

- format a range and deliver it to the inserter
- insert inside the formatted range
-   -> delta=[{"insert":"a"},{"insert":"bXcd","attributes":{"bold":true}},{"insert":"efgh"}], inserted X inherits bold=true

### S6.4

-   -> left boundary=[{"insert":"aL"},{"insert":"bcd","attributes":{"bold":true}},{"insert":"efgh"}], right boundary=[{"insert":"a"},{"insert":"bcdR","attributes":{"bold":true}},{"insert":"efgh"}]

### S6.5

- format and delete overlapping text concurrently
-   -> forward=[{"insert":"a"},{"insert":"b","attributes":{"bold":true}},{"insert":"efgh"}], reversed=[{"insert":"a"},{"insert":"b","attributes":{"bold":true}},{"insert":"efgh"}]

### S6.6

- format and delete in the same area concurrently
-   -> forward=[{"insert":"a"},{"insert":"bcef","attributes":{"bold":true}},{"insert":"gh"}], reversed=[{"insert":"a"},{"insert":"bcef","attributes":{"bold":true}},{"insert":"gh"}]

### S6.7

- toggle bold twenty times and decode each full state
-   -> sizes=159,183,179,199,193,213,207,227,221,241,235,255,249,269,263,283,277,297,291,311; ContentFormat counts=2,3,2,3,2,3,2,3,2,3,2,3,2,3,2,3,2,3,2,3
