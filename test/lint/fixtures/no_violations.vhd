-------------------------------------------------------------------------------
-- File: no_violations.vhd
-- Description: Test fixture with no lint diagnostics under the default rules
-- Author: Test
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

-- Registered pass-through of one data bit
entity no_violations is
    port (
        -- System clock
        clk : in std_logic;
        -- Synchronous active-high reset
        rst : in std_logic;
        -- Input data bit
        data_in : in std_logic;
        -- Registered data bit
        data_out : out std_logic
    );
end entity no_violations;

architecture rtl of no_violations is

    -- Data register
    signal data_reg : std_logic;

begin

    -- Register the input bit
    reg_proc : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                data_reg <= '0';
            else
                data_reg <= data_in;
            end if;
        end if;
    end process reg_proc;

    data_out <= data_reg;

end architecture rtl;
