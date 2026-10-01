/*
 * XInput reload gate: load and free xinput1_3.dll repeatedly, as games do.
 *
 * Copyright 2026 the Kitsune project
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * An unloaded image's arena range is never handed out again, so a DLL that a
 * game loads and frees every second used the arena up. XInput pins itself:
 * every load must land at the same address and a free must not unload it.
 */

#include <windows.h>
#include <stdio.h>

int main( void )
{
    HMODULE first = NULL;
    int i;

    for (i = 0; i < 100; i++)
    {
        HMODULE h = LoadLibraryA( "xinput1_3.dll" );

        if (!h)
        {
            printf( "FAIL load %d error %lu\n", i, GetLastError() );
            return 1;
        }
        if (!GetProcAddress( h, "XInputGetState" ))
        {
            printf( "FAIL no XInputGetState\n" );
            return 1;
        }
        if (!first) first = h;
        else if (h != first)
        {
            printf( "FAIL load %d at %p, first at %p\n", i, h, first );
            return 1;
        }
        FreeLibrary( h );
    }
    if (GetModuleHandleA( "xinput1_3.dll" ) != first)
    {
        printf( "FAIL xinput1_3.dll unloaded\n" );
        return 1;
    }
    printf( "OK xinput stays loaded across 100 loads at %p\n", first );
    return 0;
}
