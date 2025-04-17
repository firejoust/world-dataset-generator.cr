# World Dataset Generator

This program generates Minecraft-style worlds based on a configuration specified in a JSON file. Designed for creating RL datasets quickly, it supports layered generation, probabilistic block/structure placement, recursive structures, named areas, and random world rotation. The generated worlds are exported into a custom, compressed binary format using palettes for efficiency.

## Features

*   **JSON Configuration:** Define world generation rules using a flexible JSON format.
*   **Layered Generation:** Build worlds layer by layer, specifying volumes and their contents.
*   **Probabilistic Placement:** Use "Percentage Objects" to define chances for placing different blocks or structures.
*   **Recursive Structures:** Define complex structures composed of blocks and other structures.
*   **Named Areas:** Define specific volumes (like "start" or "end" points) within the world.
*   **Random Rotation:** Each generated world instance is randomly rotated (0, 90, 180, or 270 degrees).
*   **Multiple World Generation:** Generate several unique world instances from a single configuration.
*   **Compressed Binary Output:** Exports worlds to a Zlib-compressed binary file.
*   **Palette Optimization:** Uses palettes for block state IDs and area definitions in the binary format to reduce file size.
*   **Coordinate System:** Operates within a -128 to +127 boundary for X, Y, and Z axes.

## Prerequisites

*   **Crystal Compiler:** You need the Crystal language compiler installed. See the [official Crystal installation guide](https://crystal-lang.org/install/).

## Usage

Compile and run the script from your terminal:

```bash
crystal run world-dataset-generator.cr <config_file.json> <output_file.bin> <world_count>
```

**Arguments:**

1.  `<config_file.json>`: Path to the input JSON configuration file defining the world generation rules.
2.  `<output_file.bin>`: Path where the output compressed binary file will be saved.
3.  `<world_count>`: The number of unique world instances to generate and include in the output file.

## Input JSON Format (`<config_file.json>`)

The configuration file uses JSON to describe how worlds should be generated. Here's the structure defined using TypeScript types for clarity:

```typescript
// Represents a position string like "x,y,z"
type PositionString = string;

// Represents a percentage string key in a PercentageObject.
// Example: "50%", "25%_comment", "10%_another_outcome"
// The numerical percentage before the '%' is used for probability calculation.
// Any text after the '%' is ignored for calculation but ensures key uniqueness in JSON.
type PercentageString = string;

// Possible values within a Percentage Object or Structure Definition
type ProbabilisticValue = number | string | PercentageObject;

// An object defining percentage chances for different outcomes
interface PercentageObject {
  [key: PercentageString]: ProbabilisticValue;
  // Note: The sum of the *numerical percentages* extracted from the keys
  // (the part before the '%') in this object MUST equal 100%.
  // Air (block ID 0) must be explicitly included if it's a possible outcome.
}

// Defines a layer in the world
interface Layer {
  start: PositionString; // Min corner "x,y,z"
  end: PositionString;   // Max corner "x,y,z"
  contents: number | string | PercentageObject; // Block ID, Structure Name, or Percentage Object
}

// Defines the blocks/structures within a named structure
interface StructureDefinition {
  [relativePosition: PositionString]: number | string | PercentageObject; // Block ID, Structure Name, or Percentage Object at relative "x,y,z"
}

// Defines a named area volume
interface AreaDefinition {
  start: PositionString; // Min corner "x,y,z"
  end: PositionString;   // Max corner "x,y,z"
}

// The top-level configuration object
interface WorldConfig {
  layers: Layer[];
  structures: {
    [structureName: string]: StructureDefinition;
  };
  areas: {
    [areaName: string]: AreaDefinition;
  };
}
```

**Key Sections:**

*   **`layers`**: An array of `Layer` objects. Each defines a rectangular volume (`start` to `end` coordinates) and its `contents`.
    *   `contents` can be:
        *   A block state ID (`number`).
        *   A structure name (`string`).
        *   A `PercentageObject` for probabilistic placement within the volume.
*   **`structures`**: An object mapping structure names (`string`) to `StructureDefinition` objects.
    *   `StructureDefinition` maps relative positions (`PositionString` from the structure's origin) to a block ID, another structure name, or a `PercentageObject`. This allows for recursive structures.
*   **`areas`**: An object mapping area names (`string`) to `AreaDefinition` objects, each defining a volume with `start` and `end` coordinates.
*   **`PercentageObject`**:
    *   Keys are `PercentageString`s (e.g., `"75%"`, `"25%_comment"`). The number before the `%` is parsed for probability; text after `%` is ignored but allows duplicate numerical percentages (e.g., `"50%_a"` and `"50%_b"`).
    *   The **sum of numerical percentages** within an object *must* equal 100%.
    *   **Air (block ID 0) must be explicitly included** if it's a possible outcome.
    *   Values can be block IDs, structure names, or nested `PercentageObject`s.
*   **`PositionString`**: All coordinates are strings formatted as `"x,y,z"`.

## Output Binary Format (`<output_file.bin>`)

The output file is a **Zlib-compressed** binary file containing one or more generated world instances. All multi-byte integers are stored in **Little Endian** format.

**File Structure:**

1.  **File Header:**
    *   `schema_version` (UInt32): The version of this binary format (currently `1`).
    *   `world_count` (UInt32): The total number of world instances in this file.

2.  **Block State Palette:** (Maps palette indices used later to actual block IDs)
    *   `palette_entry_count` (UInt8): Number of unique non-air block state IDs used across all worlds (max 256).
    *   `palette_entries` (Array[UInt16]): Repeated `palette_entry_count` times. Each entry is the actual `Block State ID` (UInt16). The index of the entry (0 to `palette_entry_count - 1`) is used in the per-world block data.

3.  **Area Definition Palette:** (Maps palette indices used later to specific area names and *rotated* coordinates)
    *   `area_palette_entry_count` (UInt16): Total number of area definition entries. This includes entries for each original area defined in the JSON, potentially duplicated for each of the 4 possible rotations if their coordinates differ after rotation.
    *   `area_palette_entries` (Array): Repeated `area_palette_entry_count` times. Each entry contains:
        *   `area_name_length` (UInt8): Length of the original area name string.
        *   `area_name_chars` (N Bytes, ASCII): The characters of the original area name.
        *   `Start X` (Int8): The X coordinate of the area's start corner *after rotation*.
        *   `Start Y` (Int8): The Y coordinate of the area's start corner *after rotation*.
        *   `Start Z` (Int8): The Z coordinate of the area's start corner *after rotation*.
        *   `End X` (Int8): The X coordinate of the area's end corner *after rotation*.
        *   `End Y` (Int8): The Y coordinate of the area's end corner *after rotation*.
        *   `End Z` (Int8): The Z coordinate of the area's end corner *after rotation*.
        *   The index of this entry (0 to `area_palette_entry_count - 1`) is used in the per-world area data.

4.  **Per-World Data:** (Repeated `world_count` times)
    *   `non_air_block_count` (UInt32): Number of non-air blocks in *this specific* world instance.
    *   `area_count` (UInt8): Number of areas associated with *this specific* world instance (max 255).
    *   **Block Data:** (Repeated `non_air_block_count` times)
        *   `X Coordinate` (Int8): Block's X position (-128 to 127).
        *   `Y Coordinate` (Int8): Block's Y position (-128 to 127).
        *   `Z Coordinate` (Int8): Block's Z position (-128 to 127).
        *   `Block Palette Index` (UInt8): The index into the `Block State Palette` corresponding to this block's state ID.
    *   **Area Data:** (Repeated `area_count` times)
        *   `Area Palette Index` (UInt16): The index into the `Area Definition Palette`. This index points to the entry containing the correct original name and the *already rotated* coordinates corresponding to this specific world instance's rotation.

**Note on Air:** Air blocks (typically block ID 0) are not explicitly stored in the block data section to save space. Any coordinate within the bounds (-128 to +127) not listed in the block data is assumed to be air.

## Example

**`example_config.json`:**

```json
{
  "layers": [
    {
      "start": "-10,-5,-10",
      "end": "10,-1,10",
      "contents": 1 // Solid layer of block ID 1 (e.g., stone)
    },
    {
      "start": "-10,0,-10",
      "end": "10,0,10",
      "contents": { // Surface layer
        "90%": 2, // 90% chance of block ID 2 (e.g., grass)
        "5%": 3,  // 5% chance of block ID 3 (e.g., dirt)
        "5%_flower": 18 // 5% chance of block ID 18 (e.g., flower), unique key
      }
    },
    {
        "start": "0,1,0",
        "end": "0,1,0",
        "contents": "small_house" // Place a structure
    }
  ],
  "structures": {
    "small_house": {
      "0,0,0": 5, // Wood plank floor
      "0,1,0": 0, // Air inside
      "0,2,0": 5, // Wood plank ceiling
      "-1,1,0": 5, // Walls
      "1,1,0": 5,
      "0,1,-1": 5,
      "0,1,1": 5
    }
  },
  "areas": {
    "spawn": {
      "start": "0,1,0",
      "end": "0,1,0"
    },
    "treasure_zone": {
        "start": "-8,-4,-8",
        "end": "-6,-2,-6"
    }
  }
}
```

**Usage Command:**

```bash
crystal run world-dataset-generator.cr example_config.json my_worlds.bin 5
```

This would generate 5 unique world instances based on `example_config.json` (each potentially rotated differently) and save them into the compressed file `my_worlds.bin`.
