-- Test fixture with naming violations
-- Expected violations:
-- - signal_naming: MySignal (should be lowercase)
-- - constant_naming: my_const (should be UPPERCASE)
-- - entity_naming: BadEntity (should be lowercase)

library ieee;
use ieee.std_logic_1164.all;

entity BadEntity is
    generic (
        data_width : integer := 8  -- VIOLATION: should be DATA_WIDTH
    );
    port (
        clk : in std_logic;
        rst : in std_logic;
        DataIn : in std_logic_vector(7 downto 0);  -- Could violate port naming if enabled
        DataOut : out std_logic_vector(7 downto 0)
    );
end entity BadEntity;

architecture rtl of BadEntity is
    signal MySignal : std_logic;  -- VIOLATION: should be my_signal
    constant my_const : integer := 42;  -- VIOLATION: should be MY_CONST
begin
    MySignal <= clk and rst;
    DataOut <= DataIn when MySignal = '1' else (others => '0');
end architecture rtl;
