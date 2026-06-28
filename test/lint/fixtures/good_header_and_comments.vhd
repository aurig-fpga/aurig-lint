-------------------------------------------------------------------------------
-- File: good_header_and_comments.vhd
-- Description: Test fixture with proper documentation comments
-- Author: Test
-- Date: 2026-02-02
-- This file demonstrates proper VHDL documentation style
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

-- Entity with properly documented ports and generics
entity good_header_and_comments is
    generic (
        -- Data width in bits
        G_DATA_WIDTH : positive := 8;
        -- Enable feature flag
        G_ENABLE_FEATURE : boolean := false
    );
    port (
        -- System clock
        clk_i : in std_logic;
        -- Active-low reset
        rst_n_i : in std_logic;
        -- Input data bus
        data_i : in std_logic_vector(G_DATA_WIDTH-1 downto 0);
        -- Data valid signal
        valid_i : in std_logic;
        -- Output data bus
        data_o : out std_logic_vector(G_DATA_WIDTH-1 downto 0);
        -- Output valid signal
        valid_o : out std_logic
    );
end entity good_header_and_comments;

architecture a_rtl of good_header_and_comments is

    -- Internal pipeline register
    signal s_data_reg : std_logic_vector(G_DATA_WIDTH-1 downto 0);
    signal s_valid_reg : std_logic;

begin

    -- Registered data path process
    proc_register: process(clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_n_i = '0' then
                s_data_reg <= (others => '0');
                s_valid_reg <= '0';
            else
                s_data_reg <= data_i;
                s_valid_reg <= valid_i;
            end if;
        end if;
    end process;

    -- Output assignment
    data_o <= s_data_reg;
    valid_o <= s_valid_reg;

end architecture a_rtl;
