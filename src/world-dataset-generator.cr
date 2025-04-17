require "json"
require "random"
require "compress/zlib"
require "log"

# Configure logging
Log.setup_from_env
logger = Log.for("minecraft_world_generator")

# Type aliases for clarity
alias PositionString = String
alias PercentageString = String
alias ProbabilisticValue = Int32 | String | Hash(String, ProbabilisticValue)
alias StructureDefinition = Hash(PositionString, ProbabilisticValue)
alias AreaDefinition = NamedTuple(start: PositionString, end_pos: PositionString)

# Position class to handle coordinates
class Position
  property x : Int32
  property y : Int32
  property z : Int32

  def initialize(@x : Int32, @y : Int32, @z : Int32)
  end

  def initialize(pos_string : String)
    parts = pos_string.split(",").map(&.strip.to_i)
    if parts.size != 3
      raise "Invalid position string: #{pos_string}"
    end
    @x = parts[0]
    @y = parts[1]
    @z = parts[2]
  end

  def to_s
    "#{@x},#{@y},#{@z}"
  end

  def rotate(rotation : Int32) : Position
    case rotation
    when 0
      return Position.new(@x, @y, @z)
    when 90
      return Position.new(-@z, @y, @x)
    when 180
      return Position.new(-@x, @y, -@z)
    when 270
      return Position.new(@z, @y, -@x)
    else
      raise "Invalid rotation: #{rotation}"
    end
  end

  def +(other : Position) : Position
    Position.new(@x + other.x, @y + other.y, @z + other.z)
  end

  def in_bounds? : Bool
    @x >= -128 && @x <= 127 && @y >= -128 && @y <= 127 && @z >= -128 && @z <= 127
  end
end

# Layer class to represent a volume in the world
class Layer
  property start : Position
  property end_pos : Position
  property contents : ProbabilisticValue

  def initialize(@start : Position, @end_pos : Position, @contents : ProbabilisticValue)
  end
end

# World class to represent a generated world instance
class World
  property blocks : Hash(Position, Int32)
  property areas : Array(NamedTuple(name: String, start: Position, end_pos: Position))
  property rotation : Int32

  def initialize
    @blocks = {} of Position => Int32
    @areas = [] of NamedTuple(name: String, start: Position, end_pos: Position)
    @rotation = Random.new.rand(4) * 90 # 0, 90, 180, or 270 degrees
  end

  def set_block(pos : Position, block_id : Int32)
    rotated_pos = pos.rotate(@rotation)
    if rotated_pos.in_bounds? && block_id != 0 # Only store non-air blocks
      @blocks[rotated_pos] = block_id
    end
  end

  def add_area(name : String, start : Position, end_pos : Position)
    rotated_start = start.rotate(@rotation)
    rotated_end = end_pos.rotate(@rotation)

    # Ensure start is always the min corner and end is the max corner after rotation
    min_x = Math.min(rotated_start.x, rotated_end.x)
    min_y = Math.min(rotated_start.y, rotated_end.y)
    min_z = Math.min(rotated_start.z, rotated_end.z)

    max_x = Math.max(rotated_start.x, rotated_end.x)
    max_y = Math.max(rotated_start.y, rotated_end.y)
    max_z = Math.max(rotated_start.z, rotated_end.z)

    @areas << {
      name:    name,
      start:   Position.new(min_x, min_y, min_z),
      end_pos: Position.new(max_x, max_y, max_z),
    }
  end
end

# WorldGenerator class to handle world generation
class WorldGenerator
  property config : JSON::Any
  property structures : Hash(String, StructureDefinition)
  property areas : Hash(String, AreaDefinition)
  property rng : Random

  def initialize(config_file : String)
    puts "Loading configuration from #{config_file}"
    @config = JSON.parse(File.read(config_file))
    @structures = {} of String => StructureDefinition
    @areas = {} of String => AreaDefinition
    @rng = Random.new

    # Parse structures
    if @config["structures"]?
      puts "Parsing #{@config["structures"].as_h.size} structures"
      @config["structures"].as_h.each do |name, definition|
        @structures[name] = {} of PositionString => ProbabilisticValue
        definition.as_h.each do |pos_str, value|
          @structures[name][pos_str] = parse_probabilistic_value(value)
        end
      end
    end

    # Parse areas
    if @config["areas"]?
      puts "Parsing #{@config["areas"].as_h.size} areas"
      @config["areas"].as_h.each do |name, definition|
        @areas[name] = {
          start:   definition["start"].as_s,
          end_pos: definition["end"].as_s,
        }
      end
    end
  end

  # Parse a probabilistic value from JSON
  def parse_probabilistic_value(value : JSON::Any) : ProbabilisticValue
    if value.as_i?
      return value.as_i
    elsif value.as_s?
      return value.as_s
    elsif value.as_h?
      result = {} of String => ProbabilisticValue
      value.as_h.each do |k, v|
        result[k] = parse_probabilistic_value(v)
      end
      return result
    else
      raise "Invalid probabilistic value type: #{value}"
    end
  end

  # Resolve a probabilistic value to a concrete block ID
  def resolve_value(value : ProbabilisticValue, world : World, pos : Position, structure_origin : Position? = nil) : Nil
    case value
    when Int32
      world.set_block(pos, value)
    when String
      if @structures.has_key?(value)
        place_structure(world, value, pos)
      else
        raise "Unknown structure: #{value}"
      end
    when Hash
      # Handle percentage object
      total_percentage = 0
      choices = [] of Tuple(Int32, ProbabilisticValue)

      value.each do |key, val|
        # Parse percentage from key (e.g., "75%" or "25%_comment")
        match = key.match(/^(\d+)%/)
        if match
          percentage = match[1].to_i
          total_percentage += percentage
          choices << {percentage, val}
        else
          raise "Invalid percentage key: #{key}"
        end
      end

      # Verify total percentage is 100%
      if total_percentage != 100
        raise "Percentage sum must be 100%, got #{total_percentage}%"
      end

      # Make a random choice based on percentages
      roll = @rng.rand(100)
      cumulative = 0

      choices.each do |percentage, val|
        cumulative += percentage
        if roll < cumulative
          resolve_value(val, world, pos, structure_origin)
          break
        end
      end
    end
  end

  # Place a structure at the given position
  def place_structure(world : World, structure_name : String, origin : Position)
    structure = @structures[structure_name]
    structure.each do |rel_pos_str, value|
      rel_pos = Position.new(rel_pos_str)
      abs_pos = origin + rel_pos
      resolve_value(value, world, abs_pos, origin)
    end
  end

  # Generate a single world instance
  def generate_world : World
    world = World.new

    # Process layers
    @config["layers"].as_a.each_with_index do |layer_data, index|
      start_pos = Position.new(layer_data["start"].as_s)
      end_pos = Position.new(layer_data["end"].as_s)
      contents = parse_probabilistic_value(layer_data["contents"])

      # Ensure start is min corner and end is max corner
      min_x = Math.min(start_pos.x, end_pos.x)
      min_y = Math.min(start_pos.y, end_pos.y)
      min_z = Math.min(start_pos.z, end_pos.z)

      max_x = Math.max(start_pos.x, end_pos.x)
      max_y = Math.max(start_pos.y, end_pos.y)
      max_z = Math.max(start_pos.z, end_pos.z)

      volume = (max_x - min_x + 1) * (max_y - min_y + 1) * (max_z - min_z + 1)

      # Fill the layer
      (min_x..max_x).each do |x|
        (min_y..max_y).each do |y|
          (min_z..max_z).each do |z|
            pos = Position.new(x, y, z)
            resolve_value(contents, world, pos)
          end
        end
      end
    end

    # Add areas to the world
    @areas.each do |name, area_def|
      start_pos = Position.new(area_def[:start])
      end_pos = Position.new(area_def[:end_pos])
      world.add_area(name, start_pos, end_pos)
    end

    puts "Done (#{world.blocks.size} blocks)"
    return world
  end

  # Generate multiple world instances
  def generate_worlds(count : Int32) : Array(World)
    puts "Generating #{count} worlds"
    worlds = [] of World
    count.times do |i|
      print "Generating world #{i + 1}/#{count}... "
      worlds << generate_world
    end
    puts "Completed generation of #{count} worlds."
    return worlds
  end
end

# WorldExporter class to handle binary file output
class WorldExporter
  SCHEMA_VERSION = 1_u32

  # Export worlds to a binary file
  def self.export(worlds : Array(World), output_file : String)
    # Build block state palette (unique non-air block IDs)
    block_palette = Set(Int32).new
    worlds.each do |world|
      world.blocks.values.each do |block_id|
        block_palette.add(block_id)
      end
    end
    block_palette_array = block_palette.to_a.sort

    # Build area definition palette
    area_palette = [] of NamedTuple(name: String, start: Position, end_pos: Position)
    worlds.each do |world|
      world.areas.each do |area|
        # Only add unique entries to the palette
        unless area_palette.any? { |entry| entry[:name] == area[:name] &&
               entry[:start].to_s == area[:start].to_s &&
               entry[:end_pos].to_s == area[:end_pos].to_s }
          area_palette << area
        end
      end
    end

    puts "Exporting binary file to #{output_file}..."

    # Write binary file
    File.open(output_file, "w") do |file|
      io = Compress::Zlib::Writer.new(file)

      # Write file header
      io.write_bytes(SCHEMA_VERSION, IO::ByteFormat::LittleEndian)
      io.write_bytes(worlds.size.to_u32, IO::ByteFormat::LittleEndian)

      # Write block state palette
      io.write_byte(block_palette_array.size.to_u8)
      block_palette_array.each do |block_id|
        io.write_bytes(block_id.to_u16, IO::ByteFormat::LittleEndian)
      end

      # Write area definition palette
      io.write_bytes(area_palette.size.to_u16, IO::ByteFormat::LittleEndian)
      area_palette.each do |area|
        # Write area name
        io.write_byte(area[:name].bytesize.to_u8)
        io.write(area[:name].to_slice)

        # Write area coordinates
        io.write_byte((area[:start].x & 0xFF).to_u8)
        io.write_byte((area[:start].y & 0xFF).to_u8)
        io.write_byte((area[:start].z & 0xFF).to_u8)
        io.write_byte((area[:end_pos].x & 0xFF).to_u8)
        io.write_byte((area[:end_pos].y & 0xFF).to_u8)
        io.write_byte((area[:end_pos].z & 0xFF).to_u8)
      end

      # Write per-world data
      worlds.each do |world|
        # Write non-air block count
        io.write_bytes(world.blocks.size.to_u32, IO::ByteFormat::LittleEndian)

        # Write area count
        io.write_byte(world.areas.size.to_u8)

        # Write block data
        world.blocks.each do |pos, block_id|
          io.write_byte((pos.x & 0xFF).to_u8)
          io.write_byte((pos.y & 0xFF).to_u8)
          io.write_byte((pos.z & 0xFF).to_u8)

          # Find block palette index
          palette_index = block_palette_array.index(block_id)
          if palette_index.nil?
            raise "Block ID #{block_id} not found in palette"
          end
          io.write_byte(palette_index.to_u8)
        end

        # Write area data
        world.areas.each do |area|
          # Find area palette index
          area_index = area_palette.index do |entry|
            entry[:name] == area[:name] &&
              entry[:start].to_s == area[:start].to_s &&
              entry[:end_pos].to_s == area[:end_pos].to_s
          end

          if area_index.nil?
            raise "Area not found in palette: #{area[:name]}"
          end

          io.write_bytes(area_index.to_u16, IO::ByteFormat::LittleEndian)
        end
      end

      io.close
    end
  end
end

# Main program
if ARGV.size < 3
  puts "Usage: crystal minecraft_world_generator.cr <config_file.json> <output_file.bin> <world_count>"
  exit(1)
end

config_file = ARGV[0]
output_file = ARGV[1]
world_count = ARGV[2].to_i

begin
  generator = WorldGenerator.new(config_file)
  worlds = generator.generate_worlds(world_count)
  WorldExporter.export(worlds, output_file)
  puts "Successfully generated #{world_count} worlds and saved to #{output_file}"
rescue ex
  puts "Error: #{ex.message}"
  exit(1)
end
