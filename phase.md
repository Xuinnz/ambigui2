### Phase 1: The Data Structures (The Foundation)
Start by defining exactly how a board and a piece exist in memory.

If you are using standard arrays, define your 10x20 grid.

If you are going the high-performance bitboard route, define your arrays of u16 or u64 integers.

Hardcode the binary/hexadecimal representations of the 7 standard Tetromino shapes.

### Phase 2: The Core Physics (Movement & Collisions)
Write the functions that manipulate the data. You need to be able to move a piece without the game crashing.

Write move_left(), move_right(), shift_down(), and rotate().

Write the check_collision() function. This is the most critical function in the entire project. It must perfectly detect if a piece has hit the wall, the floor, or a locked block.

### Phase 3: The Quantum Mechanic & Line Clears
Once standard Tetris physics work, introduce your custom rules.

Write the function that locks a piece into the board.

Write the "Quantum Collapse" logic (e.g., generating the random number to decide if the piece resolves into Shape A or Shape B).

Write the clear_lines() function. Have it scan the board, remove full rows, pull the blocks down, and apply your custom 1-line penalty if triggered.

### Phase 4: The Terminal Renderer
Write a simple print_board() function that loops through your data structure and prints [] for a block and . for empty space.

Write a basic game loop that accepts keyboard input so you can play the game in the terminal. If you can play it flawlessly, the AI can play it flawlessly.

### Phase 5: The AI (Expectimax + GA)
Only once the game is fully playable by a human do you start writing the AI logic. You'll build the Expectimax search tree, give it hardcoded heuristic weights first to make sure it can "see," and then finally write the Genetic Algorithm wrapper to train it overnight.