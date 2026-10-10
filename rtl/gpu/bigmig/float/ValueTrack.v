// Float
// https://github.com/ToNi3141/Float
// Copyright (c) 2021 ToNi3141

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// This module observes the incoming and outgoing values of a pipeline
// to give feedback if a value is still in the pipeline. 
// This can be useful when it is required to check, if the pipeline is
// empty or not.
// This module is pipelined
module ValueTrack
(
    input  wire aclk,
    input  wire resetn,

    input  wire sigIncomingValue,
    input  wire sigOutgoingValue,
    output reg  valueInPipeline
);
    reg [7 : 0] valuesCounter = 0;

    always @(posedge aclk)
    begin
        if (!resetn)
        begin
            valuesCounter <= 0;
        end
        else
        begin
            // Value comes into the pipeline and goes out --> obviously the pipeline contains values
            if ((sigOutgoingValue == 1) && (sigIncomingValue == 1)) 
            begin
                valueInPipeline <= 1;
            end
            // Value goes out and no values comes in. 
            // The pipeline loses a value (decrement) but still contains something
            if ((sigOutgoingValue == 1) && (sigIncomingValue == 0))
            begin
                valuesCounter <= valuesCounter - 1;
                valueInPipeline <= 1;
            end
            // No values goes out but one comes in
            // The pipeline receives a new values (increment) therefor it contains values
            if ((sigOutgoingValue == 0) && (sigIncomingValue == 1))
            begin
                valuesCounter <= valuesCounter + 1;
                valueInPipeline <= 1;
            end
            // Nothing goes in or out. But the pipeline could still contain values.
            // Check the counter if values are still processed
            if ((sigOutgoingValue == 0) && (sigIncomingValue == 0))
            begin
                valueInPipeline <= valuesCounter != 0;
            end      
        end
    end
endmodule
