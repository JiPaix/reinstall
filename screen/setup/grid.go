package main

import "math"

// Cell is one monitor placed in a grid, with its chosen settings.
type Cell struct {
	Connector string
	W, H      int     // native pixels of the chosen mode
	ModeSpec  string  // base "WxH@refresh" (the engine appends +vrr when VRR=true)
	Scale     float64 //
	Color     string  // default | bt2100 | sdr-native
	VRR       bool
	Primary   bool
}

func (c Cell) logicalW() int { return int(math.Round(float64(c.W) / c.Scale)) }
func (c Cell) logicalH() int { return int(math.Round(float64(c.H) / c.Scale)) }

// Profile is a grid: rows of cells, where the index within a row is its column.
// Row 0 is the ground; higher-indexed rows stack on top (negative Y).
type Profile struct {
	Rows [][]Cell
}

// Placed is a cell with its computed logical position.
type Placed struct {
	Cell
	X, Y int
}

// columnGeom returns, per column index, the column width (max logical width of
// any cell in that column) and its left x-origin (cumulative).
func columnGeom(rows [][]Cell) (colX, colW []int) {
	ncols := 0
	for _, r := range rows {
		if len(r) > ncols {
			ncols = len(r)
		}
	}
	colW = make([]int, ncols)
	for _, row := range rows {
		for c, cell := range row {
			if w := cell.logicalW(); w > colW[c] {
				colW[c] = w
			}
		}
	}
	colX = make([]int, ncols)
	for c := 1; c < ncols; c++ {
		colX[c] = colX[c-1] + colW[c-1]
	}
	return colX, colW
}

// rowHeights returns the height (max logical height) of each row.
func rowHeights(rows [][]Cell) []int {
	h := make([]int, len(rows))
	for r, row := range rows {
		for _, cell := range row {
			if v := cell.logicalH(); v > h[r] {
				h[r] = v
			}
		}
	}
	return h
}

// AutoAlign lays out a grid into non-negative logical coordinates. Each cell is
// centered horizontally within its column; rows are top-aligned. Internally row
// 0 sits at y=0 and higher-indexed rows stack on top (negative y); the result is
// then normalized so the bounding box starts at (0, 0) — Mutter rejects any
// negative logical-monitor position.
func (p Profile) AutoAlign() []Placed {
	colX, colW := columnGeom(p.Rows)
	rowH := rowHeights(p.Rows)

	rowTopY := make([]int, len(p.Rows))
	for r := 1; r < len(p.Rows); r++ {
		rowTopY[r] = rowTopY[r-1] - rowH[r]
	}

	var out []Placed
	for r, row := range p.Rows {
		for c, cell := range row {
			out = append(out, Placed{
				Cell: cell,
				X:    colX[c] + (colW[c]-cell.logicalW())/2,
				Y:    rowTopY[r],
			})
		}
	}
	return normalize(out)
}

// normalize shifts every position so the layout's minimum x and y are both 0.
func normalize(ps []Placed) []Placed {
	if len(ps) == 0 {
		return ps
	}
	minX, minY := ps[0].X, ps[0].Y
	for _, p := range ps {
		if p.X < minX {
			minX = p.X
		}
		if p.Y < minY {
			minY = p.Y
		}
	}
	for i := range ps {
		ps[i].X -= minX
		ps[i].Y -= minY
	}
	return ps
}
