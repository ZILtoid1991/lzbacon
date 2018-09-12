module lzbacon.symbolCodec;

import core.stdc.string;
import core.stdc.stdlib;

import lzbacon.prefixCoding;
import lzbacon.huffmanCodes;

import lzbacon.system;
/*currently disabled*/
/*
static if(ENABLE_INTEL_INTRINSICS){
	import intel-intrinsics;
}
*/

const uint cSymbolCodecArithMinLen = 0x01000000U;
const uint cSymbolCodecArithMaxLen = 0xFFFFFFFFU;

const uint cSymbolCodecArithProbBits = 11;
const uint cSymbolCodecArithProbScale = 1 << cSymbolCodecArithProbBits;
const uint cSymbolCodecArithProbHalfScale = 1 << (cSymbolCodecArithProbBits - 1);
const uint cSymbolCodecArithProbMoveBits = 5;

const uint cBitCostScaleShift = 24;
const uint cBitCostScale = (1U << cBitCostScaleShift);
const ulong cBitCostMax = ulong.max;

immutable int LZHAM_DEFAULT_MAX_UPDATE_INTERVAL = 64;
immutable uint LZHAM_DEFAULT_ADAPT_RATE = 64;

uint[cSymbolCodecArithProbScale] gProbCost = 
   [
      0x0,0xB000000,0xA000000,0x96A3FE6,0x9000000,0x8AD961F,0x86A3FE6,0x8315130,0x8000000,0x7D47FCC,0x7AD961F,
      0x78A62B0,0x76A3FE6,0x74CAFFC,0x7315130,0x717D605,0x7000000,0x6E99C09,0x6D47FCC,0x6C087D3,0x6AD961F,0x69B9116,
      0x68A62B0,0x679F7D8,0x66A3FE6,0x65B2C3E,0x64CAFFC,0x63EBFB1,0x6315130,0x6245B5C,0x617D605,0x60BB9CA,0x6000000,
      0x5F4A296,0x5E99C09,0x5DEE74F,0x5D47FCC,0x5CA6144,0x5C087D3,0x5B6EFE1,0x5AD961F,0x5A47779,0x59B9116,0x592E050,
      0x58A62B0,0x58215EA,0x579F7D8,0x5720677,0x56A3FE6,0x562A260,0x55B2C3E,0x553DBEF,0x54CAFFC,0x545A701,0x53EBFB1,
      0x537F8CF,0x5315130,0x52AC7B8,0x5245B5C,0x51E0B1B,0x517D605,0x511BB33,0x50BB9CA,0x505D0FC,0x5000000,0x4FA461A,
      0x4F4A296,0x4EF14C7,0x4E99C09,0x4E437BE,0x4DEE74F,0x4D9AA2C,0x4D47FCC,0x4CF67A8,0x4CA6144,0x4C56C23,0x4C087D3,
      0x4BBB3E1,0x4B6EFE1,0x4B23B6D,0x4AD961F,0x4A8FF97,0x4A47779,0x49FFD6A,0x49B9116,0x4973228,0x492E050,0x48E9B41,
      0x48A62B0,0x4863655,0x48215EA,0x47E012C,0x479F7D8,0x475F9B0,0x4720677,0x46E1DF1,0x46A3FE6,0x4666C1D,0x462A260,
      0x45EE27C,0x45B2C3E,0x4577F74,0x453DBEF,0x4504180,0x44CAFFC,0x4492735,0x445A701,0x4422F38,0x43EBFB1,0x43B5846,
      0x437F8CF,0x434A129,0x4315130,0x42E08C0,0x42AC7B8,0x4278DF7,0x4245B5C,0x4212FC7,0x41E0B1B,0x41AED39,0x417D605,
      0x414C561,0x411BB33,0x40EB75F,0x40BB9CA,0x408C25C,0x405D0FC,0x402E58F,0x4000000,0x3FD2036,0x3FA461A,0x3F77197,
      0x3F4A296,0x3F1D903,0x3EF14C7,0x3EC55D0,0x3E99C09,0x3E6E75F,0x3E437BE,0x3E18D14,0x3DEE74F,0x3DC465D,0x3D9AA2C,
      0x3D712AC,0x3D47FCC,0x3D1F17A,0x3CF67A8,0x3CCE246,0x3CA6144,0x3C7E492,0x3C56C23,0x3C2F7E8,0x3C087D3,0x3BE1BD5,
      0x3BBB3E1,0x3B94FE9,0x3B6EFE1,0x3B493BC,0x3B23B6D,0x3AFE6E7,0x3AD961F,0x3AB4908,0x3A8FF97,0x3A6B9C0,0x3A47779,
      0x3A238B5,0x39FFD6A,0x39DC58E,0x39B9116,0x3995FF7,0x3973228,0x395079E,0x392E050,0x390BC34,0x38E9B41,0x38C7D6E,
      0x38A62B0,0x3884B01,0x3863655,0x38424A6,0x38215EA,0x3800A1A,0x37E012C,0x37BFB18,0x379F7D8,0x377F762,0x375F9B0,
      0x373FEBA,0x3720677,0x37010E1,0x36E1DF1,0x36C2DA0,0x36A3FE6,0x36854BC,0x3666C1D,0x3648600,0x362A260,0x360C136,
      0x35EE27C,0x35D062B,0x35B2C3E,0x35954AD,0x3577F74,0x355AC8C,0x353DBEF,0x3520D98,0x3504180,0x34E77A4,0x34CAFFC,
      0x34AEA83,0x3492735,0x347660B,0x345A701,0x343EA12,0x3422F38,0x340766F,0x33EBFB1,0x33D0AFA,0x33B5846,0x339A78E,
      0x337F8CF,0x3364C05,0x334A129,0x332F839,0x3315130,0x32FAC09,0x32E08C0,0x32C6751,0x32AC7B8,0x32929F1,0x3278DF7,
      0x325F3C6,0x3245B5C,0x322C4B2,0x3212FC7,0x31F9C96,0x31E0B1B,0x31C7B53,0x31AED39,0x31960CB,0x317D605,0x3164CE2,
      0x314C561,0x3133F7D,0x311BB33,0x310387F,0x30EB75F,0x30D37CE,0x30BB9CA,0x30A3D50,0x308C25C,0x30748EC,0x305D0FC,
      0x3045A88,0x302E58F,0x301720E,0x3000000,0x2FE8F64,0x2FD2036,0x2FBB274,0x2FA461A,0x2F8DB27,0x2F77197,0x2F60968,
      0x2F4A296,0x2F33D20,0x2F1D903,0x2F0763B,0x2EF14C7,0x2EDB4A5,0x2EC55D0,0x2EAF848,0x2E99C09,0x2E84111,0x2E6E75F,
      0x2E58EEE,0x2E437BE,0x2E2E1CB,0x2E18D14,0x2E03996,0x2DEE74F,0x2DD963D,0x2DC465D,0x2DAF7AD,0x2D9AA2C,0x2D85DD7,
      0x2D712AC,0x2D5C8A9,0x2D47FCC,0x2D33812,0x2D1F17A,0x2D0AC02,0x2CF67A8,0x2CE246A,0x2CCE246,0x2CBA13A,0x2CA6144,
      0x2C92262,0x2C7E492,0x2C6A7D4,0x2C56C23,0x2C43180,0x2C2F7E8,0x2C1BF5A,0x2C087D3,0x2BF5151,0x2BE1BD5,0x2BCE75A,
      0x2BBB3E1,0x2BA8166,0x2B94FE9,0x2B81F68,0x2B6EFE1,0x2B5C153,0x2B493BC,0x2B3671A,0x2B23B6D,0x2B110B1,0x2AFE6E7,
      0x2AEBE0C,0x2AD961F,0x2AC6F1E,0x2AB4908,0x2AA23DC,0x2A8FF97,0x2A7DC39,0x2A6B9C0,0x2A5982B,0x2A47779,0x2A357A7,
      0x2A238B5,0x2A11AA1,0x29FFD6A,0x29EE10F,0x29DC58E,0x29CAAE6,0x29B9116,0x29A781C,0x2995FF7,0x29848A6,0x2973228,
      0x2961C7B,0x295079E,0x293F390,0x292E050,0x291CDDD,0x290BC34,0x28FAB56,0x28E9B41,0x28D8BF4,0x28C7D6E,0x28B6FAD,
      0x28A62B0,0x2895677,0x2884B01,0x287404B,0x2863655,0x2852D1F,0x28424A6,0x2831CEA,0x28215EA,0x2810FA5,0x2800A1A,
      0x27F0547,0x27E012C,0x27CFDC7,0x27BFB18,0x27AF91E,0x279F7D8,0x278F744,0x277F762,0x276F831,0x275F9B0,0x274FBDE,
      0x273FEBA,0x2730242,0x2720677,0x2710B57,0x27010E1,0x26F1715,0x26E1DF1,0x26D2575,0x26C2DA0,0x26B3670,0x26A3FE6,
      0x26949FF,0x26854BC,0x267601C,0x2666C1D,0x26578BE,0x2648600,0x26393E1,0x262A260,0x261B17D,0x260C136,0x25FD18C,
      0x25EE27C,0x25DF407,0x25D062B,0x25C18E8,0x25B2C3E,0x25A402A,0x25954AD,0x25869C6,0x2577F74,0x25695B6,0x255AC8C,
      0x254C3F4,0x253DBEF,0x252F47B,0x2520D98,0x2512744,0x2504180,0x24F5C4B,0x24E77A4,0x24D9389,0x24CAFFC,0x24BCCFA,
      0x24AEA83,0x24A0897,0x2492735,0x248465C,0x247660B,0x2468643,0x245A701,0x244C847,0x243EA12,0x2430C63,0x2422F38,
      0x2415292,0x240766F,0x23F9ACF,0x23EBFB1,0x23DE515,0x23D0AFA,0x23C3160,0x23B5846,0x23A7FAB,0x239A78E,0x238CFF0,
      0x237F8CF,0x237222C,0x2364C05,0x2357659,0x234A129,0x233CC74,0x232F839,0x2322478,0x2315130,0x2307E61,0x22FAC09,
      0x22EDA29,0x22E08C0,0x22D37CE,0x22C6751,0x22B974A,0x22AC7B8,0x229F89B,0x22929F1,0x2285BBA,0x2278DF7,0x226C0A6,
      0x225F3C6,0x2252758,0x2245B5C,0x2238FCF,0x222C4B2,0x221FA05,0x2212FC7,0x22065F7,0x21F9C96,0x21ED3A2,0x21E0B1B,
      0x21D4301,0x21C7B53,0x21BB410,0x21AED39,0x21A26CD,0x21960CB,0x2189B33,0x217D605,0x217113F,0x2164CE2,0x21588EE,
      0x214C561,0x214023B,0x2133F7D,0x2127D25,0x211BB33,0x210F9A6,0x210387F,0x20F77BD,0x20EB75F,0x20DF765,0x20D37CE,
      0x20C789B,0x20BB9CA,0x20AFB5C,0x20A3D50,0x2097FA6,0x208C25C,0x2080574,0x20748EC,0x2068CC4,0x205D0FC,0x2051593,
      0x2045A88,0x2039FDD,0x202E58F,0x2022BA0,0x201720E,0x200B8D8,0x2000000,0x1FF4784,0x1FE8F64,0x1FDD79F,0x1FD2036,
      0x1FC6928,0x1FBB274,0x1FAFC1A,0x1FA461A,0x1F99074,0x1F8DB27,0x1F82633,0x1F77197,0x1F6BD53,0x1F60968,0x1F555D3,
      0x1F4A296,0x1F3EFB0,0x1F33D20,0x1F28AE6,0x1F1D903,0x1F12774,0x1F0763B,0x1EFC557,0x1EF14C7,0x1EE648C,0x1EDB4A5,
      0x1ED0511,0x1EC55D0,0x1EBA6E3,0x1EAF848,0x1EA49FF,0x1E99C09,0x1E8EE64,0x1E84111,0x1E79410,0x1E6E75F,0x1E63AFE,
      0x1E58EEE,0x1E4E32E,0x1E437BE,0x1E38C9D,0x1E2E1CB,0x1E23748,0x1E18D14,0x1E0E32E,0x1E03996,0x1DF904C,0x1DEE74F,
      0x1DE3E9F,0x1DD963D,0x1DCEE27,0x1DC465D,0x1DB9EDF,0x1DAF7AD,0x1DA50C7,0x1D9AA2C,0x1D903DC,0x1D85DD7,0x1D7B81C,
      0x1D712AC,0x1D66D86,0x1D5C8A9,0x1D52416,0x1D47FCC,0x1D3DBCA,0x1D33812,0x1D294A2,0x1D1F17A,0x1D14E9B,0x1D0AC02,
      0x1D009B2,0x1CF67A8,0x1CEC5E6,0x1CE246A,0x1CD8335,0x1CCE246,0x1CC419D,0x1CBA13A,0x1CB011C,0x1CA6144,0x1C9C1B0,
      0x1C92262,0x1C88358,0x1C7E492,0x1C74611,0x1C6A7D4,0x1C609DA,0x1C56C23,0x1C4CEB0,0x1C43180,0x1C39493,0x1C2F7E8,
      0x1C25B80,0x1C1BF5A,0x1C12375,0x1C087D3,0x1BFEC71,0x1BF5151,0x1BEB673,0x1BE1BD5,0x1BD8177,0x1BCE75A,0x1BC4D7D,
      0x1BBB3E1,0x1BB1A84,0x1BA8166,0x1B9E888,0x1B94FE9,0x1B8B789,0x1B81F68,0x1B78786,0x1B6EFE1,0x1B6587B,0x1B5C153,
      0x1B52A69,0x1B493BC,0x1B3FD4D,0x1B3671A,0x1B2D125,0x1B23B6D,0x1B1A5F1,0x1B110B1,0x1B07BAE,0x1AFE6E7,0x1AF525C,
      0x1AEBE0C,0x1AE29F8,0x1AD961F,0x1AD0281,0x1AC6F1E,0x1ABDBF6,0x1AB4908,0x1AAB655,0x1AA23DC,0x1A9919C,0x1A8FF97,
      0x1A86DCB,0x1A7DC39,0x1A74AE0,0x1A6B9C0,0x1A628DA,0x1A5982B,0x1A507B6,0x1A47779,0x1A3E774,0x1A357A7,0x1A2C812,
      0x1A238B5,0x1A1A98F,0x1A11AA1,0x1A08BEA,0x19FFD6A,0x19F6F21,0x19EE10F,0x19E5333,0x19DC58E,0x19D381F,0x19CAAE6,
      0x19C1DE3,0x19B9116,0x19B047E,0x19A781C,0x199EBEF,0x1995FF7,0x198D434,0x19848A6,0x197BD4D,0x1973228,0x196A737,
      0x1961C7B,0x19591F3,0x195079E,0x1947D7D,0x193F390,0x19369D7,0x192E050,0x19256FD,0x191CDDD,0x19144EF,0x190BC34,
      0x19033AC,0x18FAB56,0x18F2333,0x18E9B41,0x18E1382,0x18D8BF4,0x18D0498,0x18C7D6E,0x18BF675,0x18B6FAD,0x18AE916,
      0x18A62B0,0x189DC7C,0x1895677,0x188D0A4,0x1884B01,0x187C58E,0x187404B,0x186BB38,0x1863655,0x185B1A2,0x1852D1F,
      0x184A8CB,0x18424A6,0x183A0B1,0x1831CEA,0x1829953,0x18215EA,0x18192B0,0x1810FA5,0x1808CC8,0x1800A1A,0x17F8799,
      0x17F0547,0x17E8322,0x17E012C,0x17D7F63,0x17CFDC7,0x17C7C59,0x17BFB18,0x17B7A05,0x17AF91E,0x17A7865,0x179F7D8,
      0x1797778,0x178F744,0x178773D,0x177F762,0x17777B4,0x176F831,0x17678DB,0x175F9B0,0x1757AB1,0x174FBDE,0x1747D36,
      0x173FEBA,0x1738068,0x1730242,0x1728447,0x1720677,0x17188D2,0x1710B57,0x1708E07,0x17010E1,0x16F93E6,0x16F1715,
      0x16E9A6E,0x16E1DF1,0x16DA19E,0x16D2575,0x16CA976,0x16C2DA0,0x16BB1F3,0x16B3670,0x16ABB16,0x16A3FE6,0x169C4DE,
      0x16949FF,0x168CF49,0x16854BC,0x167DA58,0x167601C,0x166E608,0x1666C1D,0x165F25A,0x16578BE,0x164FF4B,0x1648600,
      0x1640CDD,0x16393E1,0x1631B0D,0x162A260,0x16229DB,0x161B17D,0x1613946,0x160C136,0x160494D,0x15FD18C,0x15F59F0,
      0x15EE27C,0x15E6B2E,0x15DF407,0x15D7D06,0x15D062B,0x15C8F77,0x15C18E8,0x15BA280,0x15B2C3E,0x15AB621,0x15A402A,
      0x159CA59,0x15954AD,0x158DF27,0x15869C6,0x157F48A,0x1577F74,0x1570A82,0x15695B6,0x156210E,0x155AC8C,0x155382E,
      0x154C3F4,0x1544FDF,0x153DBEF,0x1536823,0x152F47B,0x15280F7,0x1520D98,0x1519A5C,0x1512744,0x150B450,0x1504180,
      0x14FCED4,0x14F5C4B,0x14EE9E6,0x14E77A4,0x14E0585,0x14D9389,0x14D21B1,0x14CAFFC,0x14C3E69,0x14BCCFA,0x14B5BAD,
      0x14AEA83,0x14A797C,0x14A0897,0x14997D5,0x1492735,0x148B6B7,0x148465C,0x147D622,0x147660B,0x146F616,0x1468643,
      0x1461691,0x145A701,0x1453793,0x144C847,0x144591C,0x143EA12,0x1437B2A,0x1430C63,0x1429DBD,0x1422F38,0x141C0D5,
      0x1415292,0x140E470,0x140766F,0x140088F,0x13F9ACF,0x13F2D30,0x13EBFB1,0x13E5253,0x13DE515,0x13D77F8,0x13D0AFA,
      0x13C9E1D,0x13C3160,0x13BC4C3,0x13B5846,0x13AEBE8,0x13A7FAB,0x13A138D,0x139A78E,0x1393BAF,0x138CFF0,0x1386450,
      0x137F8CF,0x1378D6E,0x137222C,0x136B709,0x1364C05,0x135E11F,0x1357659,0x1350BB2,0x134A129,0x13436C0,0x133CC74,
      0x1336248,0x132F839,0x1328E4A,0x1322478,0x131BAC5,0x1315130,0x130E7B9,0x1307E61,0x1301526,0x12FAC09,0x12F430A,
      0x12EDA29,0x12E7166,0x12E08C0,0x12DA038,0x12D37CE,0x12CCF81,0x12C6751,0x12BFF3F,0x12B974A,0x12B2F73,0x12AC7B8,
      0x12A601B,0x129F89B,0x1299137,0x12929F1,0x128C2C7,0x1285BBA,0x127F4CA,0x1278DF7,0x1272740,0x126C0A6,0x1265A28,
      0x125F3C6,0x1258D81,0x1252758,0x124C14C,0x1245B5C,0x123F587,0x1238FCF,0x1232A33,0x122C4B2,0x1225F4E,0x121FA05,
      0x12194D8,0x1212FC7,0x120CAD1,0x12065F7,0x1200139,0x11F9C96,0x11F380E,0x11ED3A2,0x11E6F51,0x11E0B1B,0x11DA700,
      0x11D4301,0x11CDF1C,0x11C7B53,0x11C17A4,0x11BB410,0x11B5097,0x11AED39,0x11A89F6,0x11A26CD,0x119C3BF,0x11960CB,
      0x118FDF2,0x1189B33,0x118388F,0x117D605,0x1177395,0x117113F,0x116AF04,0x1164CE2,0x115EADB,0x11588EE,0x115271A,
      0x114C561,0x11463C1,0x114023B,0x113A0CF,0x1133F7D,0x112DE44,0x1127D25,0x1121C1F,0x111BB33,0x1115A60,0x110F9A6,
      0x1109906,0x110387F,0x10FD811,0x10F77BD,0x10F1781,0x10EB75F,0x10E5755,0x10DF765,0x10D978D,0x10D37CE,0x10CD828,
      0x10C789B,0x10C1926,0x10BB9CA,0x10B5A87,0x10AFB5C,0x10A9C4A,0x10A3D50,0x109DE6F,0x1097FA6,0x10920F5,0x108C25C,
      0x10863DC,0x1080574,0x107A724,0x10748EC,0x106EACC,0x1068CC4,0x1062ED4,0x105D0FC,0x105733B,0x1051593,0x104B802,
      0x1045A88,0x103FD27,0x1039FDD,0x10342AA,0x102E58F,0x102888C,0x1022BA0,0x101CECB,0x101720E,0x1011567,0x100B8D8,
      0x1005C61,0x1000000,0xFFA3B6,0xFF4784,0xFEEB68,0xFE8F64,0xFE3376,0xFDD79F,0xFD7BDF,0xFD2036,0xFCC4A3,
      0xFC6928,0xFC0DC2,0xFBB274,0xFB573C,0xFAFC1A,0xFAA10F,0xFA461A,0xF9EB3C,0xF99074,0xF935C2,0xF8DB27,
      0xF880A2,0xF82633,0xF7CBDA,0xF77197,0xF7176A,0xF6BD53,0xF66353,0xF60968,0xF5AF93,0xF555D3,0xF4FC2A,
      0xF4A296,0xF44918,0xF3EFB0,0xF3965D,0xF33D20,0xF2E3F9,0xF28AE6,0xF231EA,0xF1D903,0xF18031,0xF12774,
      0xF0CECD,0xF0763B,0xF01DBF,0xEFC557,0xEF6D05,0xEF14C7,0xEEBC9F,0xEE648C,0xEE0C8E,0xEDB4A5,0xED5CD0,
      0xED0511,0xECAD66,0xEC55D0,0xEBFE4F,0xEBA6E3,0xEB4F8B,0xEAF848,0xEAA119,0xEA49FF,0xE9F2FA,0xE99C09,
      0xE9452D,0xE8EE64,0xE897B1,0xE84111,0xE7EA86,0xE79410,0xE73DAD,0xE6E75F,0xE69124,0xE63AFE,0xE5E4EC,
      0xE58EEE,0xE53904,0xE4E32E,0xE48D6C,0xE437BE,0xE3E223,0xE38C9D,0xE3372A,0xE2E1CB,0xE28C80,0xE23748,
      0xE1E224,0xE18D14,0xE13817,0xE0E32E,0xE08E58,0xE03996,0xDFE4E7,0xDF904C,0xDF3BC4,0xDEE74F,0xDE92ED,
      0xDE3E9F,0xDDEA64,0xDD963D,0xDD4228,0xDCEE27,0xDC9A38,0xDC465D,0xDBF295,0xDB9EDF,0xDB4B3D,0xDAF7AD,
      0xDAA431,0xDA50C7,0xD9FD70,0xD9AA2C,0xD956FB,0xD903DC,0xD8B0D0,0xD85DD7,0xD80AF1,0xD7B81C,0xD7655B,
      0xD712AC,0xD6C010,0xD66D86,0xD61B0E,0xD5C8A9,0xD57656,0xD52416,0xD4D1E7,0xD47FCC,0xD42DC2,0xD3DBCA,
      0xD389E5,0xD33812,0xD2E651,0xD294A2,0xD24305,0xD1F17A,0xD1A001,0xD14E9B,0xD0FD46,0xD0AC02,0xD05AD1,
      0xD009B2,0xCFB8A4,0xCF67A8,0xCF16BE,0xCEC5E6,0xCE751F,0xCE246A,0xCDD3C7,0xCD8335,0xCD32B5,0xCCE246,
      0xCC91E9,0xCC419D,0xCBF163,0xCBA13A,0xCB5122,0xCB011C,0xCAB127,0xCA6144,0xCA1171,0xC9C1B0,0xC97200,
      0xC92262,0xC8D2D4,0xC88358,0xC833ED,0xC7E492,0xC79549,0xC74611,0xC6F6EA,0xC6A7D4,0xC658CE,0xC609DA,
      0xC5BAF6,0xC56C23,0xC51D61,0xC4CEB0,0xC48010,0xC43180,0xC3E301,0xC39493,0xC34635,0xC2F7E8,0xC2A9AC,
      0xC25B80,0xC20D64,0xC1BF5A,0xC1715F,0xC12375,0xC0D59C,0xC087D3,0xC03A1A,0xBFEC71,0xBF9ED9,0xBF5151,
      0xBF03DA,0xBEB673,0xBE691B,0xBE1BD5,0xBDCE9E,0xBD8177,0xBD3461,0xBCE75A,0xBC9A64,0xBC4D7D,0xBC00A7,
      0xBBB3E1,0xBB672A,0xBB1A84,0xBACDED,0xBA8166,0xBA34EF,0xB9E888,0xB99C31,0xB94FE9,0xB903B1,0xB8B789,
      0xB86B71,0xB81F68,0xB7D36F,0xB78786,0xB73BAC,0xB6EFE1,0xB6A427,0xB6587B,0xB60CDF,0xB5C153,0xB575D6,
      0xB52A69,0xB4DF0B,0xB493BC,0xB4487D,0xB3FD4D,0xB3B22C,0xB3671A,0xB31C18,0xB2D125,0xB28641,0xB23B6D,
      0xB1F0A7,0xB1A5F1,0xB15B4A,0xB110B1,0xB0C628,0xB07BAE,0xB03143,0xAFE6E7,0xAF9C9A,0xAF525C,0xAF082C,
      0xAEBE0C,0xAE73FA,0xAE29F8,0xADE004,0xAD961F,0xAD4C49,0xAD0281,0xACB8C8,0xAC6F1E,0xAC2583,0xABDBF6,
      0xAB9278,0xAB4908,0xAAFFA7,0xAAB655,0xAA6D11,0xAA23DC,0xA9DAB5,0xA9919C,0xA94893,0xA8FF97,0xA8B6AA,
      0xA86DCB,0xA824FB,0xA7DC39,0xA79386,0xA74AE0,0xA70249,0xA6B9C0,0xA67146,0xA628DA,0xA5E07B,0xA5982B,
      0xA54FEA,0xA507B6,0xA4BF90,0xA47779,0xA42F6F,0xA3E774,0xA39F87,0xA357A7,0xA30FD6,0xA2C812,0xA2805D,
      0xA238B5,0xA1F11B,0xA1A98F,0xA16211,0xA11AA1,0xA0D33F,0xA08BEA,0xA044A4,0x9FFD6A,0x9FB63F,0x9F6F21,
      0x9F2811,0x9EE10F,0x9E9A1B,0x9E5333,0x9E0C5A,0x9DC58E,0x9D7ED0,0x9D381F,0x9CF17C,0x9CAAE6,0x9C645E,
      0x9C1DE3,0x9BD776,0x9B9116,0x9B4AC3,0x9B047E,0x9ABE46,0x9A781C,0x9A31FF,0x99EBEF,0x99A5EC,0x995FF7,
      0x991A0F,0x98D434,0x988E67,0x9848A6,0x9802F3,0x97BD4D,0x9777B4,0x973228,0x96ECA9,0x96A737,0x9661D3,
      0x961C7B,0x95D730,0x9591F3,0x954CC2,0x95079E,0x94C287,0x947D7D,0x943880,0x93F390,0x93AEAD,0x9369D7,
      0x93250D,0x92E050,0x929BA0,0x9256FD,0x921266,0x91CDDD,0x91895F,0x9144EF,0x91008B,0x90BC34,0x9077EA,
      0x9033AC,0x8FEF7B,0x8FAB56,0x8F673E,0x8F2333,0x8EDF34,0x8E9B41,0x8E575B,0x8E1382,0x8DCFB5,0x8D8BF4,
      0x8D4840,0x8D0498,0x8CC0FD,0x8C7D6E,0x8C39EB,0x8BF675,0x8BB30B,0x8B6FAD,0x8B2C5B,0x8AE916,0x8AA5DD,
      0x8A62B0,0x8A1F90,0x89DC7C,0x899973,0x895677,0x891388,0x88D0A4,0x888DCC,0x884B01,0x880841,0x87C58E,
      0x8782E6,0x87404B,0x86FDBC,0x86BB38,0x8678C1,0x863655,0x85F3F6,0x85B1A2,0x856F5B,0x852D1F,0x84EAEF,
      0x84A8CB,0x8466B3,0x8424A6,0x83E2A6,0x83A0B1,0x835EC8,0x831CEA,0x82DB19,0x829953,0x825799,0x8215EA,
      0x81D448,0x8192B0,0x815125,0x810FA5,0x80CE31,0x808CC8,0x804B6B,0x800A1A,0x7FC8D4,0x7F8799,0x7F466A,
      0x7F0547,0x7EC42F,0x7E8322,0x7E4221,0x7E012C,0x7DC041,0x7D7F63,0x7D3E8F,0x7CFDC7,0x7CBD0B,0x7C7C59,
      0x7C3BB3,0x7BFB18,0x7BBA89,0x7B7A05,0x7B398C,0x7AF91E,0x7AB8BC,0x7A7865,0x7A3819,0x79F7D8,0x79B7A2,
      0x797778,0x793759,0x78F744,0x78B73B,0x78773D,0x78374A,0x77F762,0x77B786,0x7777B4,0x7737ED,0x76F831,
      0x76B881,0x7678DB,0x763940,0x75F9B0,0x75BA2B,0x757AB1,0x753B42,0x74FBDE,0x74BC84,0x747D36,0x743DF2,
      0x73FEBA,0x73BF8C,0x738068,0x734150,0x730242,0x72C33F,0x728447,0x72455A,0x720677,0x71C79F,0x7188D2,
      0x714A0F,0x710B57,0x70CCAA,0x708E07,0x704F6F,0x7010E1,0x6FD25E,0x6F93E6,0x6F5578,0x6F1715,0x6ED8BC,
      0x6E9A6E,0x6E5C2B,0x6E1DF1,0x6DDFC3,0x6DA19E,0x6D6385,0x6D2575,0x6CE770,0x6CA976,0x6C6B86,0x6C2DA0,
      0x6BEFC4,0x6BB1F3,0x6B742D,0x6B3670,0x6AF8BE,0x6ABB16,0x6A7D79,0x6A3FE6,0x6A025D,0x69C4DE,0x69876A,
      0x6949FF,0x690C9F,0x68CF49,0x6891FE,0x6854BC,0x681785,0x67DA58,0x679D35,0x67601C,0x67230D,0x66E608,
      0x66A90D,0x666C1D,0x662F36,0x65F25A,0x65B587,0x6578BE,0x653C00,0x64FF4B,0x64C2A1,0x648600,0x644969,
      0x640CDD,0x63D05A,0x6393E1,0x635772,0x631B0D,0x62DEB2,0x62A260,0x626619,0x6229DB,0x61EDA7,0x61B17D,
      0x61755D,0x613946,0x60FD39,0x60C136,0x60853D,0x60494D,0x600D68,0x5FD18C,0x5F95B9,0x5F59F0,0x5F1E31,
      0x5EE27C,0x5EA6D0,0x5E6B2E,0x5E2F96,0x5DF407,0x5DB882,0x5D7D06,0x5D4194,0x5D062B,0x5CCACC,0x5C8F77,
      0x5C542B,0x5C18E8,0x5BDDAF,0x5BA280,0x5B675A,0x5B2C3E,0x5AF12B,0x5AB621,0x5A7B21,0x5A402A,0x5A053D,
      0x59CA59,0x598F7E,0x5954AD,0x5919E5,0x58DF27,0x58A472,0x5869C6,0x582F23,0x57F48A,0x57B9FA,0x577F74,
      0x5744F6,0x570A82,0x56D018,0x5695B6,0x565B5E,0x56210E,0x55E6C8,0x55AC8C,0x557258,0x55382E,0x54FE0C,
      0x54C3F4,0x5489E5,0x544FDF,0x5415E2,0x53DBEF,0x53A204,0x536823,0x532E4A,0x52F47B,0x52BAB5,0x5280F7,
      0x524743,0x520D98,0x51D3F5,0x519A5C,0x5160CC,0x512744,0x50EDC6,0x50B450,0x507AE4,0x504180,0x500826,
      0x4FCED4,0x4F958B,0x4F5C4B,0x4F2314,0x4EE9E6,0x4EB0C0,0x4E77A4,0x4E3E90,0x4E0585,0x4DCC83,0x4D9389,
      0x4D5A99,0x4D21B1,0x4CE8D2,0x4CAFFC,0x4C772E,0x4C3E69,0x4C05AD,0x4BCCFA,0x4B944F,0x4B5BAD,0x4B2314,
      0x4AEA83,0x4AB1FB,0x4A797C,0x4A4105,0x4A0897,0x49D031,0x4997D5,0x495F80,0x492735,0x48EEF2,0x48B6B7,
      0x487E85,0x48465C,0x480E3B,0x47D622,0x479E13,0x47660B,0x472E0C,0x46F616,0x46BE28,0x468643,0x464E66,
      0x461691,0x45DEC5,0x45A701,0x456F46,0x453793,0x44FFE9,0x44C847,0x4490AD,0x44591C,0x442193,0x43EA12,
      0x43B29A,0x437B2A,0x4343C2,0x430C63,0x42D50C,0x429DBD,0x426676,0x422F38,0x41F802,0x41C0D5,0x4189AF,
      0x415292,0x411B7D,0x40E470,0x40AD6B,0x40766F,0x403F7B,0x40088F,0x3FD1AB,0x3F9ACF,0x3F63FB,0x3F2D30,
      0x3EF66D,0x3EBFB1,0x3E88FE,0x3E5253,0x3E1BB0,0x3DE515,0x3DAE83,0x3D77F8,0x3D4175,0x3D0AFA,0x3CD488,
      0x3C9E1D,0x3C67BB,0x3C3160,0x3BFB0E,0x3BC4C3,0x3B8E80,0x3B5846,0x3B2213,0x3AEBE8,0x3AB5C5,0x3A7FAB,
      0x3A4998,0x3A138D,0x39DD89,0x39A78E,0x39719B,0x393BAF,0x3905CC,0x38CFF0,0x389A1C,0x386450,0x382E8C,
      0x37F8CF,0x37C31B,0x378D6E,0x3757C9,0x37222C,0x36EC96,0x36B709,0x368183,0x364C05,0x36168E,0x35E11F,
      0x35ABB9,0x357659,0x354102,0x350BB2,0x34D66A,0x34A129,0x346BF1,0x3436C0,0x340196,0x33CC74,0x33975A,
      0x336248,0x332D3D,0x32F839,0x32C33E,0x328E4A,0x32595D,0x322478,0x31EF9B,0x31BAC5,0x3185F7,0x315130,
      0x311C71,0x30E7B9,0x30B309,0x307E61,0x3049C0,0x301526,0x2FE094,0x2FAC09,0x2F7786,0x2F430A,0x2F0E96,
      0x2EDA29,0x2EA5C4,0x2E7166,0x2E3D0F,0x2E08C0,0x2DD479,0x2DA038,0x2D6BFF,0x2D37CE,0x2D03A4,0x2CCF81,
      0x2C9B66,0x2C6751,0x2C3345,0x2BFF3F,0x2BCB41,0x2B974A,0x2B635B,0x2B2F73,0x2AFB92,0x2AC7B8,0x2A93E6,
      0x2A601B,0x2A2C57,0x29F89B,0x29C4E5,0x299137,0x295D90,0x2929F1,0x28F658,0x28C2C7,0x288F3D,0x285BBA,
      0x28283F,0x27F4CA,0x27C15D,0x278DF7,0x275A98,0x272740,0x26F3EF,0x26C0A6,0x268D63,0x265A28,0x2626F4,
      0x25F3C6,0x25C0A0,0x258D81,0x255A69,0x252758,0x24F44F,0x24C14C,0x248E50,0x245B5C,0x24286E,0x23F587,
      0x23C2A8,0x238FCF,0x235CFD,0x232A33,0x22F76F,0x22C4B2,0x2291FD,0x225F4E,0x222CA6,0x21FA05,0x21C76B,
      0x2194D8,0x21624C,0x212FC7,0x20FD49,0x20CAD1,0x209861,0x2065F7,0x203395,0x200139,0x1FCEE4,0x1F9C96,
      0x1F6A4F,0x1F380E,0x1F05D5,0x1ED3A2,0x1EA176,0x1E6F51,0x1E3D32,0x1E0B1B,0x1DD90A,0x1DA700,0x1D74FD,
      0x1D4301,0x1D110B,0x1CDF1C,0x1CAD34,0x1C7B53,0x1C4978,0x1C17A4,0x1BE5D7,0x1BB410,0x1B8250,0x1B5097,
      0x1B1EE5,0x1AED39,0x1ABB94,0x1A89F6,0x1A585E,0x1A26CD,0x19F542,0x19C3BF,0x199241,0x1960CB,0x192F5B,
      0x18FDF2,0x18CC8F,0x189B33,0x1869DE,0x18388F,0x180746,0x17D605,0x17A4C9,0x177395,0x174267,0x17113F,
      0x16E01E,0x16AF04,0x167DF0,0x164CE2,0x161BDC,0x15EADB,0x15B9E1,0x1588EE,0x155801,0x15271A,0x14F63A,
      0x14C561,0x14948E,0x1463C1,0x1432FB,0x14023B,0x13D182,0x13A0CF,0x137023,0x133F7D,0x130EDD,0x12DE44,
      0x12ADB1,0x127D25,0x124C9F,0x121C1F,0x11EBA6,0x11BB33,0x118AC6,0x115A60,0x112A00,0x10F9A6,0x10C953,
      0x109906,0x1068BF,0x10387F,0x100845,0xFD811,0xFA7E4,0xF77BD,0xF479C,0xF1781,0xEE76D,0xEB75F,
      0xE8757,0xE5755,0xE275A,0xDF765,0xDC776,0xD978D,0xD67AA,0xD37CE,0xD07F8,0xCD828,0xCA85E,
      0xC789B,0xC48DD,0xC1926,0xBE975,0xBB9CA,0xB8A26,0xB5A87,0xB2AEF,0xAFB5C,0xACBD0,0xA9C4A,
      0xA6CCA,0xA3D50,0xA0DDC,0x9DE6F,0x9AF07,0x97FA6,0x9504A,0x920F5,0x8F1A6,0x8C25C,0x89319,
      0x863DC,0x834A5,0x80574,0x7D649,0x7A724,0x77805,0x748EC,0x719D9,0x6EACC,0x6BBC5,0x68CC4,
      0x65DC9,0x62ED4,0x5FFE5,0x5D0FC,0x5A218,0x5733B,0x54464,0x51593,0x4E6C7,0x4B802,0x48942,
      0x45A88,0x42BD5,0x3FD27,0x3CE7F,0x39FDD,0x37141,0x342AA,0x3141A,0x2E58F,0x2B70B,0x2888C,
      0x25A13,0x22BA0,0x1FD33,0x1CECB,0x1A069,0x1720E,0x143B8,0x11567,0xE71D,0xB8D8,0x8A9A,
      0x5C61,0x2E2D
   ];

public static @nogc ulong convertToScaledBitcost(uint bits){
	assert(bits <= 255);
	uint scaledBits = bits<<cBitCostScaleShift;
	return cast(ulong)scaledBits;
}

public class RawQuasiAdaptiveHuffmanDataModel{
	public ushort[] mInitialSymFreq;
	public ushort[] mSymFreq;

	public ushort[] mCodes;
	public ubyte[] mCodeSizes;

	DecoderTables   m_pDecodeTables;	///this was a pointer originally, changed it since D treats classes as reference values

	public uint mTotalSyms;
	public uint mMaxCycle;
	public uint mUpdateCycle;
	public uint mSymbolsUntilUpdate;
	public uint mTotalCount;
	public ubyte mDecoderTableBits;
	public ushort mMaxUpdateInterval; /// default is 16, typical range 12-128, controls the max interval between table updates, higher=longer max interval (faster decode/lower ratio)
	public ushort mAdaptRate; /// default is 10, 8 or higher, scaled by 8, controls the slowing of the update update freq, higher=more rapid slowing (faster decode/lower ratio)
	public bool mEncoding;

	public this(bool encoding = false, uint totalSyms = 0, uint maxUpdateInterval = 0, uint adaptRate = 0){
		
	}
	public this(const RawQuasiAdaptiveHuffmanDataModel other){
		
	}
	~this(){
		//deallocation should be done by the GC
		/*if(m_pDecodeTables){
			free(cast(void*)m_pDecodeTables);
		}*/
	}
	/*public @nogc bool opAssign(const RawQuasiAdaptiveHuffmanDataModel rhs){
		
	}*/
	/**
	 * Changed from the original.
	 */
	public RawQuasiAdaptiveHuffmanDataModel assign(RawQuasiAdaptiveHuffmanDataModel rhs){
		if(this == rhs){
			return this;
		}

		mTotalSyms = rhs.mTotalSyms;
		mMaxCycle = rhs.mMaxCycle;
		mUpdateCycle = rhs.mUpdateCycle;
		mSymbolsUntilUpdate = rhs.mSymbolsUntilUpdate;

		mTotalCount = rhs.mTotalCount;

		mSymFreq = rhs.mSymFreq;
		mInitialSymFreq = rhs.mInitialSymFreq;

		mCodes = rhs.mCodes;
		mCodeSizes = rhs.mCodeSizes;

		if(rhs.m_pDecodeTables){
			if(m_pDecodeTables){
				if(!m_pDecodeTables.assign(rhs.m_pDecodeTables)){
					clear();
					return null;
				}
			}else{
				m_pDecodeTables = (rhs.m_pDecodeTables);
				if(!m_pDecodeTables){
					clear();
					return null;
				}
			}
		}else if (m_pDecodeTables){
			//free(cast(void*)m_pDecodeTables);

			m_pDecodeTables = null;
		}
		mDecoderTableBits = rhs.mDecoderTableBits;
		mEncoding = rhs.mEncoding;
		mMaxUpdateInterval = rhs.mMaxUpdateInterval;
		mAdaptRate = rhs.mAdaptRate;
		return this;
	}
	public void clear(){
		mSymFreq.length = 0;
		mInitialSymFreq.length = 0;
		mCodes.length = 0;
		mCodeSizes.length = 0;

		mMaxCycle = 0;
		mTotalSyms = 0;
		mUpdateCycle = 0;
		mSymbolsUntilUpdate = 0;
		mDecoderTableBits = 0;
		mTotalCount = 0;

		if (m_pDecodeTables){
			//lzham_delete(m_pDecode_tables);
			m_pDecodeTables = null;	//this should also call the destructor for it
		}

		mMaxUpdateInterval = 0;
		mAdaptRate = 0;
	}
	bool init2(bool encoding, uint totalSyms, uint maxUpdateInterval, uint adaptRate, const ushort *pInitialSymFreq){
		assert(maxUpdateInterval <= 0xFFFF);
		assert(adaptRate <= 0xFFFF);

		mEncoding = encoding;
		mMaxUpdateInterval = cast(ushort)(maxUpdateInterval);
		mAdaptRate = cast(ushort)(adaptRate);
		mSymbolsUntilUpdate = 0;

		mSymFreq.length = totalSyms;

		if(pInitialSymFreq){
			mInitialSymFreq.length = totalSyms;
			memcpy(mInitialSymFreq.ptr, pInitialSymFreq, totalSyms * mInitialSymFreq.length * ushort.sizeof);// argument n is suspicious!
		}

		mCodeSizes.length = totalSyms;

		mTotalSyms = totalSyms;

		uint maxTableBits;

		if (mTotalSyms <= 8)
			maxTableBits = 4;
		else
			maxTableBits = 1 + ceil_log2i(mTotalSyms);

		mDecoderTableBits = cast(ubyte)(maxTableBits < cMaxTableBits ? maxTableBits : cMaxTableBits);

		if(mEncoding){
			m_pDecodeTables = null;

			mCodes.length = totalSyms;
		}else if(m_pDecodeTables is null){
			m_pDecodeTables = new DecoderTables();

			/+if (!m_pDecode_tables)
			{
				clear();
				return false;
			}+/
		}

		mMaxCycle = ((24 > mTotalSyms ? 24 : mTotalSyms) + 6) * (mMaxUpdateInterval ? mMaxUpdateInterval : LZHAM_DEFAULT_MAX_UPDATE_INTERVAL);

		mMaxCycle = mMaxCycle > 32767 ? 32767 : mMaxCycle;

		reset;

		return true;
	}
	bool reset(){
		if (!mTotalSyms)
			return true;

		bool symFreqAllOnes = false;

		if (mInitialSymFreq.length){
			mUpdateCycle = 0;
			for (uint i; i < mTotalSyms; i++){
				uint symFreq = mInitialSymFreq[i];
				mSymFreq[i] = cast(ushort)(symFreq);
            
			    // Slam m_update_cycle to a specific value so update_tables() sets m_total_count to the proper value
				mUpdateCycle += symFreq;
			}
		}else{
			for (uint i; i < mTotalSyms; i++)
				mSymFreq[i] = 1;
         
			// Slam m_update_cycle to a specific value so update_tables() sets m_total_count to the proper value
			mUpdateCycle = mTotalSyms;
         
			symFreqAllOnes = true;
		}

		mTotalCount = 0;
		mSymbolsUntilUpdate = 0;
            
		if (!updateTables(mMaxCycle > 16 ?  16 : mMaxCycle, symFreqAllOnes)) // this was 8 in the alphas
			return false;
                           
		return true;
	}

	@nogc @property uint totalSyms(){ return mTotalSyms; }

	@nogc void rescale(){
		uint totalFreq = 0;

		for (uint i ; i < mTotalSyms; i++){
			uint freq = (mSymFreq[i] + 1) >> 1;
			totalFreq += freq;
			mSymFreq[i] = cast(ushort)(freq);
		}

		mTotalCount = totalFreq;
	}
	@nogc void resetUpdateRate(){
		mTotalCount += (mUpdateCycle - mSymbolsUntilUpdate);

		debug{
			uint actualTotal = 0;
			for (uint i = 0; i < mSymFreq.length; i++)
				actualTotal += mSymFreq[i];
			assert(actualTotal == mTotalCount);
		}

		if (mTotalCount > mTotalSyms)
			rescale();

		//mSymbolsUntilUpdate = mUpdateCycle = LZHAM_MIN(8, mUpdateCycle);
		mSymbolsUntilUpdate = mUpdateCycle = 8 < mUpdateCycle ? 8 : mUpdateCycle;
	}

	bool updateSym(uint sym){
		uint freq = mSymFreq[sym];
		freq++;
		mSymFreq[sym] = cast(ushort)(freq);
		
		assert(freq <= ushort.max);
		
		if (--mSymbolsUntilUpdate == 0)
		{
			if (!updateTables())
				return false;
		}
		
		return true;
	}

	@nogc ulong getCost(uint sym) const{ 
		return convertToScaledBitcost(mCodeSizes[sym]);
	}

	bool updateTables(int forceUpdateCycle = -1, bool symFreqAllOnes = false){
		assert(!mSymbolsUntilUpdate);
		mTotalCount += mUpdateCycle;
		assert(mTotalCount <= 65535);

		while (mTotalCount >= 32768)
			rescale();

		uint maxCodeSize = 0;

		if ((symFreqAllOnes) && (mTotalSyms >= 2)){
			// Shortcut building the Huffman codes if we know all the sym freqs are 1.
			uint baseCodeSize = floor_log2i(mTotalSyms);
			uint numLeft = mTotalSyms - (1 << baseCodeSize);
			numLeft *= 2;
			if (numLeft > mTotalSyms)
				numLeft = mTotalSyms;

			memset(mCodeSizes.ptr, baseCodeSize + 1, numLeft);
			memset(&mCodeSizes[numLeft], baseCodeSize, mTotalSyms - numLeft);  
            
			maxCodeSize = baseCodeSize + (numLeft ? 1 : 0);
		}

		bool status = false;
		if (!maxCodeSize){
			//uint tableSize = getGenerateHuffmanCodesTableSize();
			uint tableSize = HuffmanWorkTables.sizeof;
			void *pTables = alloca(tableSize);

			uint totalFreq = 0;                  
			status = generateHuffmanCodes(pTables, mTotalSyms, mSymFreq.ptr, mCodeSizes.ptr, maxCodeSize, totalFreq);
			assert(status);
			assert(totalFreq == mTotalCount);
			if ((!status) || (totalFreq != mTotalCount))
				return false;

			if (maxCodeSize > cMaxExpectedCodeSize){
				status = limitMaxCodeSize(mTotalSyms, mCodeSizes.ptr, cMaxExpectedCodeSize);
				assert(status);
		        if (!status)
				return false;
			}
		}

		if (forceUpdateCycle >= 0){
			mSymbolsUntilUpdate = mUpdateCycle = forceUpdateCycle;
		}else{
			ushort currAdaptRate = mAdaptRate ? mAdaptRate : LZHAM_DEFAULT_ADAPT_RATE;
			mUpdateCycle = (31U + mUpdateCycle * (32U > currAdaptRate ? 32U : currAdaptRate)) >> 5U;

			if (mUpdateCycle > mMaxCycle)
				mUpdateCycle = mMaxCycle;

			mSymbolsUntilUpdate = mUpdateCycle;
		}
            
		if (mEncoding){
			status = generateCodes(mTotalSyms, mCodeSizes.ptr, mCodes.ptr);
		}else{
         uint actualTableBits = mDecoderTableBits;

         // Try to see if using the accel table is actually worth the trouble of constructing it.
         uint costToUseTable = (1 << actualTableBits) + 64;
         uint costToNotUseTable = mSymbolsUntilUpdate * floor_log2i(mTotalSyms);
         if (costToNotUseTable <= costToUseTable)
            actualTableBits = 0;

         status = generateDecoderTables(mTotalSyms, mCodeSizes.ptr, m_pDecodeTables, actualTableBits);
      }

      assert(status);
      if (!status)
         return false;
               
      return true;
	}
}


/**
 * Currently unused due to architectural differences between c++ and D, so it's harder to predict alignments and classes are reference values.
 * Instead it's an alias for the time being
 */
alias QuasiAdaptiveHuffmanDataModel = RawQuasiAdaptiveHuffmanDataModel;
/*public class QuasiAdaptiveHuffmanDataModel : RawQuasiAdaptiveHuffmanDataModel{


}*/
/**
 * This might become a struct later on, since it only holds a single 16bit unsigned value
 */
public struct AdaptiveBitModel{
	ushort bit0Prob = 1U << (cSymbolCodecArithProbBits - 1);
	//this() { clear(); }
	this(float prob0){
		setProbability0(prob0);
	}
	this(const AdaptiveBitModel other){
		bit0Prob = other.bit0Prob;
	}

	@nogc AdaptiveBitModel assign(const AdaptiveBitModel rhs){ 
		bit0Prob = rhs.bit0Prob;
		return this;
	}

	@nogc void clear(){
		bit0Prob  = 1U << (cSymbolCodecArithProbBits - 1);
	}

	@nogc void setProbability0(float prob0){
		int val = cast(int)(prob0 * cSymbolCodecArithProbScale);
		if(val <= 1)
			val = 1;
		else if(val > cSymbolCodecArithProbScale - 1)
			val = cSymbolCodecArithProbScale - 1;
		bit0Prob = cast(ushort)(val);
	}

	void update(uint bit){
		if (!bit)
			bit0Prob += ((cSymbolCodecArithProbScale - bit0Prob) >> cSymbolCodecArithProbMoveBits);
		else
			bit0Prob -= (bit0Prob >> cSymbolCodecArithProbMoveBits);
		assert(bit0Prob >= 1);
		assert(bit0Prob < cSymbolCodecArithProbScale);
	}

	@nogc ulong getCost(uint bit) const{ 
		return gProbCost[bit ? (cSymbolCodecArithProbScale - bit0Prob) : bit0Prob]; 
	}

}
public class AdaptiveArithDataModel{
	uint totalSyms;//try to deprecate this since D's dynamic arrays do automatic length counting
	AdaptiveBitModel[] probs;
	public this(bool encoding = true, uint totalSyms = 0){
		init(encoding, totalSyms);
	}
	public this(AdaptiveArithDataModel other){
		totalSyms = other.totalSyms;
	}

	void clear(){
		totalSyms = 0;
		probs.length = 0;
	}

	bool init(bool encoding, uint totalSyms){
		if(!totalSyms){
			clear;
			return true;
		}
		if((totalSyms < 2) || (isPowerOf2(totalSyms))){
			this.totalSyms = nextPow2(totalSyms);
		}else{
			this.totalSyms = totalSyms;
		}
		probs.length = this.totalSyms;

		return true;
	}
	bool init(bool encoding, uint totalSyms, bool fastEncoding){
		//LZHAM_NOTE_UNUSED(fast_encoding); 
		return init(encoding, totalSyms);
	}
	void reset(){
		foreach(abm ; probs){
			abm.clear;
		}
	}

	void resetUpdateRate(){
		
	}

	bool update(uint sym){
		uint node = 1;

		uint bitmask = totalSyms;

		do{
			bitmask >>= 1;

			uint bit = (sym & bitmask) ? 1 : 0;
			probs[node].update(bit);
			node = (node << 1) + bit;

		} while (bitmask > 1);

		return true;
	}

	public @nogc @property uint getTotalSyms(){ return totalSyms; }
	ulong getCost(uint sym){
		uint node = 1;

		uint bitmask = totalSyms;

		ulong cost = 0;
		do{
			bitmask >>= 1;

			uint bit = (sym & bitmask) ? 1 : 0;
			cost += probs[node].getCost(bit);
			node = (node << 1) + bit;

		}while (bitmask > 1);

		return cost;
	}
}
public class SymbolCodec{
	struct OutputSymbol{
		uint bits;
		enum{
			cArithSym = -1,
			cAlignToByteSym = -2,
			cArithInit = -3
		}
		short numBits;

		ushort arithProb0;
	}
	ubyte*					decodeBuf;
	ubyte*					decodeBufNext;
	ubyte*					decodeBufEnd;
	size_t					decodeBufSize;
	bool					decodeBufEOF;

	void delegate(size_t numBytesConsumed, void* privateData, const ubyte* buf, out size_t bufSize, out bool eofFlag)		decodeNeedBytesFunc;
	void*					decodePrivateData;
	/*Currently disabled*/
	/*static if(ENABLE_INTEL_INTRINSICS){
		m128i				bitBuf
		enum { cBitBufSize = 128 };
	}else */static if(CPU_64BIT_CAPABLE){
		ulong				bitBuf;
		enum { cBitBufSize = 64 };
	}else{
		uint				bitBuf;
		enum { cBitBufSize = 32 };
	}
	int						bitCount;

	uint					totalModelUpdates;

	ubyte[]					outputBuf;
    ubyte[]					arithOutputBuf;
	OutputSymbol[]			outputSyms;

	uint					totalBitsWritten;

	uint					arithBase;
	uint                    arithValue;
	uint					arithLength;
	uint					arithTotalBits;

	QuasiAdaptiveHuffmanDataModel     savedHuffModel;
	void*					savedModel;
	uint					savedNodeIndex;
	Mode					mode;
	enum Mode{
         Null,
         Encoding,
         Decoding
	}
	this(){
	
	}
	void reset(){
		decodeBuf = null;
		decodeBufNext = null;
		decodeBufEnd = null;
		decodeBufSize = 0;

		bitBuf = 0;
		bitCount = 0;
		totalModelUpdates = 0;
		mode = Mode.Null;
		totalBitsWritten = 0;

		arithBase = 0;
		arithValue = 0;
		arithLength = 0;
		arithTotalBits = 0;

		outputBuf.length = 0;
		arithOutputBuf.length = 0;
		outputSyms.length = 0;

		decodeNeedBytesFunc = null;
		decodePrivateData = null;
		savedHuffModel = null;
		savedModel = null;
		savedNodeIndex = 0;
	}
      
	// clear() is like reset(), except it also frees all memory.
	void clear(){
		reset;
		//outputBuf.length = 0;
		//arithOutputBuf.length = 0;
		//outputSyms.length = 0;
	}
      
	// Encoding
	bool startEncoding(uint expectedFileSize){
		mode = Mode.Encoding;

		totalModelUpdates = 0;
		totalBitsWritten = 0;

		if(!putBitsInit(expectedFileSize)){
			return false;
		}

		outputSyms.length = 0;

		arithStartEncoding();

		return true;
	}
	bool encodeBits(uint bits, uint numBits){
		assert(mode==Mode.Encoding);

		if (!numBits)
			return true;

		assert((numBits == 32) || (bits <= ((1U << numBits) - 1)));

		if (numBits > 16){
			if (!recordPutBits(bits >> 16, numBits - 16))
				return false;
			if (!recordPutBits(bits & 0xFFFF, 16))
				return false;
		}else{
			if (!recordPutBits(bits, numBits))
				return false;
		}
		return true;
	}
	bool encodeArithInit(){
		assert(mode == Mode.Encoding);

		OutputSymbol sym;
		sym.bits = 0;
		sym.numBits = OutputSymbol.cArithInit;
		sym.arithProb0 = 0;
		/*if (!m_output_syms.try_push_back(sym))
			return false;*/
		outputSyms ~= sym;

		return true;
	}
	bool encodeAlignToByte(){
		assert(mode == Mode.Encoding);

		OutputSymbol sym;
		sym.bits = 0;
		sym.numBits = OutputSymbol.cAlignToByteSym;
		sym.arithProb0 = 0;
		/*if (!m_output_syms.try_push_back(sym))
			return false;*/
		outputSyms ~= sym;

		return true;
	}
	bool encode(uint sym, QuasiAdaptiveHuffmanDataModel model){
		assert(mode == Mode.Encoding);
		assert(model.mEncoding);

		if(!recordPutBits(model.mCodes[sym], model.mCodeSizes[sym]))
			return false;

		uint freq = model.mSymFreq[sym];
		freq++;
		model.mSymFreq[sym] = cast(ushort)(freq);
      
		assert(freq <= ushort.max);

		if(--model.mSymbolsUntilUpdate == 0){
			totalModelUpdates++;
			if(!model.updateTables())
				return false;
		}
		return true;
	}
	
	
	bool encode(uint bit, AdaptiveBitModel model, bool updateModel = true){
		assert(mode == SymbolCodec.Mode.Encoding);

		arithTotalBits++;

		OutputSymbol sym;
		sym.bits = bit;
		sym.numBits = -1;
		sym.arithProb0 = model.bit0Prob;
		/*if (!m_output_syms.try_push_back(sym))
		return false;*/
		outputSyms ~= sym;

		uint x = model.bit0Prob * (arithLength >> cSymbolCodecArithProbBits);

		if(!bit){
			if(updateModel)
				model.bit0Prob += ((cSymbolCodecArithProbScale - model.bit0Prob) >> cSymbolCodecArithProbMoveBits);

			arithLength = x;
		}else{
			if(updateModel)
				model.bit0Prob -= (model.bit0Prob >> cSymbolCodecArithProbMoveBits);

			uint origBase = arithBase;
			arithBase += x;
			arithLength -= x;
			if (origBase > arithBase)
				arithPropagateCarry();
		}

		if (arithLength < cSymbolCodecArithMinLen){
			if (!arithRenormEncInterval())
				return false;
		}

		return true;
	}
	
	bool encode(uint sym, AdaptiveArithDataModel model){
		uint node = 1;

		uint bitmask = model.totalSyms;

		do{
			bitmask >>= 1;

			uint bit = (sym & bitmask) ? 1 : 0;
			if (!encode(bit, model.probs[node]))
				return false;
			node = (node << 1) + bit;

		}while(bitmask > 1);
		return true;
	}

	@nogc @property uint encodeGetTotalBitsWritten() const { return totalBitsWritten; }

	bool stopEncoding(bool supportArith){
		assert(mode == Mode.Encoding);

		if (supportArith){
			if (!arithStopEncoding())
				return false;
		}

		if (!assembleOutputBuf())
			return false;

		mode = Mode.Null;
		return true;
	}

	ref ubyte[]getEncodingBuf(){ 
		return outputBuf; 
	}
           // lzham::vector<uint8>& get_encoding_buf()        { return m_output_buf; }

      // Decoding

	//typedef void (*need_bytes_func_ptr)(size_t num_bytes_consumed, void *pPrivate_data, const uint8* &pBuf, size_t &buf_size, bool &eof_flag);

	//bool start_decoding(const uint8* pBuf, size_t buf_size, bool eof_flag = true, need_bytes_func_ptr pNeed_bytes_func = NULL, void *pPrivate_data = NULL);
	bool startDecoding(ubyte* pBuf, size_t bufSize, bool eofFlag = true, 
			void delegate(size_t numBytesConsumed, void* privateData, 
			const ubyte* buf, out size_t bufSize, out bool eofFlag) needBytesFunc = null, 
			void* privateData = null){
		if (!bufSize)
			return false;

		totalModelUpdates = 0;

		decodeBuf = pBuf;
		decodeBufNext = pBuf;
		decodeBufSize = bufSize;
		decodeBufEnd = pBuf + bufSize;

		decodeNeedBytesFunc = needBytesFunc;
		decodePrivateData = privateData;
		decodeBufEOF = eofFlag;

		bitBuf = 0;
		bitCount = 0;

		mode = Mode.Decoding;

		return true;
	}

	void decodeSetInputBuffer(ubyte* buf, size_t bufSize, ubyte* bufNext, bool eofFlag){
		decodeBuf = buf;
		decodeBufNext = bufNext;
		decodeBufSize = bufSize;
		decodeBufEnd = buf + bufSize;
		decodeBufEOF = eofFlag;
	}
	ulong decodeGetBytesConsumed() const { return decodeBufNext - decodeBuf; }
	ulong decodeGetBitsRemaining() const { return ((decodeBufEnd - decodeBufNext) << 3) + bitCount; }

	void startArithDecoding(){
		assert(mode == Mode.Decoding);

		arithLength = cSymbolCodecArithMaxLen;
		arithValue = 0;

		arithValue = (getBits(8) << 24);
		arithValue |= (getBits(8) << 16);
		arithValue |= (getBits(8) << 8);
		arithValue |= getBits(8);
	}
	uint decodeBits(uint numBits){
		assert(mode == Mode.Decoding);

		if(!numBits)
			return 0;

		if (numBits > 16){
			uint a = getBits(numBits - 16);
			uint b = getBits(16);

			return (a << 16) | b;
		}
		else
			return getBits(numBits);
	}
	uint decodePeekBits(uint numBits){
		assert(mode == Mode.Decoding);
		assert(numBits <= 25);

		if(!numBits)
			return 0;

		while(bitCount < cast(int)numBits){
			uint c = 0;
			if(decodeBufNext == decodeBufEnd){
				if(!decodeBufEOF){
					decodeNeedBytesFunc(decodeBufNext - decodeBuf, decodePrivateData, decodeBuf, decodeBufSize, decodeBufEOF);
					decodeBufEnd = decodeBuf + decodeBufSize;
					decodeBufNext = decodeBuf;
					if(decodeBufNext < decodeBufEnd) c = *decodeBufNext++;
				}
			}else
				c = *decodeBufNext++;

			bitCount += 8;
			assert(bitCount <= cBitBufSize);

			//m_bit_buf |= (static_cast<bit_buf_t>(c) << (cBitBufSize - m_bit_count));
			static if(CPU_64BIT_CAPABLE){
				bitBuf |= cast(ulong)(c) << (cBitBufSize - bitCount);
			}else{
				bitBuf |= (c) << (cBitBufSize - bitCount);
			}
		}

		return cast(uint)(bitBuf >> (cBitBufSize - numBits));
	}
	void decodeRemoveBits(uint numBits){
		assert(mode == Mode.Decoding);

		while (numBits > 16){
			removeBits(16);
			numBits -= 16;
		}

		removeBits(numBits);
	}
	void decodeAlignToByte(){
		assert(mode == Mode.Decoding);

		if(bitCount & 7){
			removeBits(bitCount & 7);
		}
	}
	int decodeRemoveByteFromBitBuf(){
		if (bitCount < 8)
			return -1;
		int result = cast(int)(bitBuf >> (cBitBufSize - 8));
		bitBuf <<= 8;
		bitCount -= 8;
		return result;
	}
	uint decode(QuasiAdaptiveHuffmanDataModel model){
		assert(mode == Mode.Decoding);
		assert(!model.mEncoding);

		const DecoderTables pTables = model.m_pDecodeTables;

		while(bitCount < (cBitBufSize - 8)){
			uint c = 0;
			if(decodeBufNext == decodeBufEnd){
				if(!decodeBufEOF){
					decodeNeedBytesFunc(decodeBufNext - decodeBuf, decodePrivateData, decodeBuf, decodeBufSize, decodeBufEOF);
					decodeBufEnd = decodeBuf + decodeBufSize;
					decodeBufNext = decodeBuf;
					if(decodeBufNext < decodeBufEnd) c = *decodeBufNext++;
				}
			}else
				c = *decodeBufNext++;

			bitCount += 8;
			//m_bit_buf |= (static_cast<bit_buf_t>(c) << (cBitBufSize - m_bit_count));
			static if(CPU_64BIT_CAPABLE){
				bitBuf |= cast(ulong)(c) << (cBitBufSize - bitCount);
			}
		}

		uint k = cast(uint)((bitBuf >> (cBitBufSize - 16)) + 1);
		uint sym, len;

		if (k <= pTables.tableMaxCode){
			uint t = pTables.lookup[bitBuf >> (cBitBufSize - pTables.tableBits)];

			assert(t != uint.max);
			sym = t & ushort.max;
			len = t >> 16;

			assert(model.mCodeSizes[sym] == len);
		}else{
			len = pTables.decodeStartCodeSize;

			for ( ; ; ){
				if (k <= pTables.maxCodes[len - 1])
					break;
				len++;
			}

			int valPtr = pTables.valPtrs[len - 1] + cast(int)((bitBuf >> (cBitBufSize - len)));

			if ((cast(uint)valPtr >= model.mTotalSyms)){
				// corrupted stream, or a bug
				assert(0);
				//return 0;
			}

			sym = pTables.sortedSymbolOrder[valPtr];
		}

		bitBuf <<= len;
		bitCount -= len;

		uint freq = model.mSymFreq[sym];
		freq++;
		model.mSymFreq[sym] = cast(ushort)(freq);
      
		assert(freq <= ushort.max);
      
		if (--model.mSymbolsUntilUpdate == 0){
			totalModelUpdates++;
			model.updateTables();
		}

		return sym;
	}
	uint decode(AdaptiveBitModel model, bool updateModel = true){
		while (arithLength < cSymbolCodecArithMinLen){
			uint c = getBits(8);
			arithValue = (arithValue << 8) | c;
			arithLength <<= 8;
		}

		uint x = model.bit0Prob * (arithLength >> cSymbolCodecArithProbBits);
		uint bit = (arithValue >= x);

		if (!bit){
			if (updateModel)
				model.bit0Prob += ((cSymbolCodecArithProbScale - model.bit0Prob) >> cSymbolCodecArithProbMoveBits);

			arithLength = x;
		}else{
			if (updateModel)
				model.bit0Prob -= (model.bit0Prob >> cSymbolCodecArithProbMoveBits);
			arithValue  -= x;
			arithLength -= x;
		}

		return bit;
	}
	uint decode(AdaptiveArithDataModel model){
		uint node = 1;
		do{
			uint bit = decode(model.probs[node]);
			node = (node << 1) + bit;
		} while (node < model.totalSyms);
		return node - model.totalSyms;
	}
	ulong stopDecoding(){
		assert(mode == Mode.Decoding);

		ulong n = decodeBufNext - decodeBuf;

		mode = Mode.Null;

		return n;
	}

	uint getTotalModelUpdates() const { return totalModelUpdates; }
	bool putBitsInit(uint expectedSize){
		bitBuf = 0;
		bitCount = cBitBufSize;

		//m_output_buf.try_resize(0);
		outputBuf.length = 0;
		/*if (!m_output_buf.try_reserve(expected_size))
			return false;*/
		if(outputBuf.reserve(expectedSize) < expectedSize){
			return false;
		}

		return true;
	}
	bool recordPutBits(uint bits, uint numBits){
		assert(mode == Mode.Encoding);

		assert(numBits <= 25);
		assert(bitCount >= 25);

		if (!numBits)
			return true;

		totalBitsWritten += numBits;

		OutputSymbol sym;
		sym.bits = bits;
		sym.numBits = cast(ushort)numBits;
		sym.arithProb0 = 0;
		/*if (!m_output_syms.try_push_back(sym))
			return false;*/
		outputSyms ~= sym;

		return true;
	}

	void arithPropagateCarry(){
		int index = arithOutputBuf.length - 1;
		while (index >= 0){
			uint c = arithOutputBuf[index];
			if (c == 0xFF)
				arithOutputBuf[index] = 0;
			else{
				arithOutputBuf[index]++;
				break;
			}
			index--;
		}	
	}
	bool arithRenormEncInterval(){
		do{
			/*if (!m_arith_output_buf.try_push_back((m_arith_base >> 24) & 0xFF))
				return false;*/
			arithOutputBuf ~= cast(ubyte)((arithBase >> 24) & 0xFF);
			totalBitsWritten += 8;

			arithBase <<= 8;
		}while((arithLength <<= 8) < cSymbolCodecArithMinLen);
		return true;
	}
	void arithStartEncoding(){
		arithOutputBuf.length = 0;
		arithBase = 0;
		arithValue = 0;
		arithLength = cSymbolCodecArithMaxLen;
		arithTotalBits = 0;
	}
	bool arithStopEncoding(){
		uint origBase = arithBase;

		if (arithLength > 2 * cSymbolCodecArithMinLen){
			arithBase  += cSymbolCodecArithMinLen;
			arithLength = (cSymbolCodecArithMinLen >> 1);
		}else{
			arithBase  += (cSymbolCodecArithMinLen >> 1);
			arithLength = (cSymbolCodecArithMinLen >> 9);
		}

		if (origBase > arithBase)
			arithPropagateCarry();

		if (!arithRenormEncInterval())
			return false;

		while (arithOutputBuf.length < 4){
			/*if (!m_arith_output_buf.try_push_back(0))
				return false;*/
			arithOutputBuf ~= 0;
			totalBitsWritten += 8;
		}
		return true;
	}

	bool putBits(uint bits, uint numBits){
		assert(numBits <= 25);
		assert(bitCount >= 25);
	
		if (!numBits)
			return true;

		bitCount -= numBits;
		//bitBuf |= (static_cast<bit_buf_t>(bits) << m_bit_count);
		static if(CPU_64BIT_CAPABLE){
			bitBuf |= cast(ulong)(bits) << bitCount;
		}else{
			bitBuf |= (bits) << bitCount;
		}

		totalBitsWritten += numBits;

		while (bitCount <= (cBitBufSize - 8)){
			/*if (!m_output_buf.try_push_back(static_cast<uint8>(m_bit_buf >> (cBitBufSize - 8))))
				return false;*/
			outputBuf ~= cast(ubyte)(bitBuf >> ((cBitBufSize - 8)));
			bitBuf <<= 8;
			bitCount += 8;
		}

		return true;
	}
	bool putBitsAlignToByte(){
		uint numBitsIn = cBitBufSize - bitCount;
		if (numBitsIn & 7){
			if (!putBits(0, 8 - (numBitsIn & 7)))
				return false;
		}
		return true;
	}
	bool flushBits(){
		return putBits(0, 7); //to ensure the last bits are flushed
	}
	bool assembleOutputBuf(){
		totalBitsWritten = 0;

		uint arithBufOfs = 0;

		// Intermix the final Arithmetic, Huffman, or plain bits to a single combined bitstream.
		// All bits from each source must be output in exactly the same order that the decompressor will read them.
		for(uint symIndex = 0; symIndex < outputSyms.length; symIndex++){
			const OutputSymbol* sym = &outputSyms[symIndex];

			if(sym.numBits == OutputSymbol.cAlignToByteSym){
				if(!putBitsAlignToByte())
					return false;
			}else if (sym.numBits == OutputSymbol.cArithInit){
				assert(arithOutputBuf.length);

				if (arithOutputBuf.length){
					arithLength = cSymbolCodecArithMaxLen;
					arithValue = 0;
					for(uint i = 0; i < 4; i++){
						const uint c = arithOutputBuf[arithBufOfs++];
						arithValue = (arithValue << 8) | c;
						if (!putBits(c, 8))
							return false;
					}
				}
			}else if (sym.numBits == OutputSymbol.cArithSym){
				// This renorm logic must match the logic used in the arithmetic decoder.
				if (arithLength < cSymbolCodecArithMinLen){
					do{
						const uint c = (arithBufOfs < arithOutputBuf.length) ? arithOutputBuf[arithBufOfs++] : 0;
						if (!putBits(c, 8))
							return false;
						arithValue = (arithValue << 8) | c;
					}while((arithLength <<= 8) < cSymbolCodecArithMinLen);
				}

				uint x = sym.arithProb0 * (arithLength >> cSymbolCodecArithProbBits);
				uint bit = (arithValue >= x);

				if (bit == 0){
					arithLength = x;
				}else{
					arithValue  -= x;
					arithLength -= x;
				}

				//LZHAM_VERIFY(bit == sym.m_bits);
				assert(bit == sym.bits);
			}else{
				// Huffman or plain bits
				if (!putBits(sym.bits, sym.numBits))
					return false;
			}
		}

		return flushBits();
	}

	uint getBits(uint numBits){
		assert(numBits <= 25);

		if (!numBits)
			return 0;

		while (bitCount < cast(int)numBits){
			uint c = 0;
			if(decodeBufNext == decodeBufEnd){
				if(!decodeBufEOF){
					decodeNeedBytesFunc(decodeBufNext - decodeBuf, decodePrivateData, decodeBuf, decodeBufSize, decodeBufEOF);
					decodeBufEnd = decodeBuf + decodeBufSize;
					decodeBufNext = decodeBuf;
					if (decodeBufNext < decodeBufEnd) c = *decodeBufNext++;
				}
			}else
				c = *decodeBufNext++;

			bitCount += 8;
			assert(bitCount <= cBitBufSize);

			//m_bit_buf |= (static_cast<bit_buf_t>(c) << (cBitBufSize - m_bit_count));
			static if(CPU_64BIT_CAPABLE){
				bitBuf |= cast(ulong)(c) << (cBitBufSize - bitCount);
			}else{
				bitBuf |= (c) << (cBitBufSize - bitCount);
			}
		}

		uint result = cast(uint)(bitBuf >> (cBitBufSize - numBits));

		bitBuf <<= numBits;
		bitCount -= numBits;

		return result;
	}
	void removeBits(uint numBits){
		assert(numBits <= 25);

		if (!numBits)
			return;

		while(bitCount < cast(int)numBits){
			uint c = 0;
			if(decodeBufNext == decodeBufEnd){
				if(!decodeBufEOF){
					decodeNeedBytesFunc(decodeBufNext - decodeBuf, decodePrivateData, decodeBuf, decodeBufSize, decodeBufEOF);
					decodeBufEnd = decodeBuf + decodeBufSize;
					decodeBufNext = decodeBuf;
					if(decodeBufNext < decodeBufEnd) c = *decodeBufNext++;
				}
			}else
				c = *decodeBufNext++;

			bitCount += 8;
			assert(bitCount <= cBitBufSize);

			//m_bit_buf |= (static_cast<bit_buf_t>(c) << (cBitBufSize - m_bit_count));
			static if(CPU_64BIT_CAPABLE){
				bitBuf |= cast(ulong)(c) << (cBitBufSize - bitCount);
			}else{
				bitBuf |= (c) << (cBitBufSize - bitCount);
			}
		}

		bitBuf <<= numBits;
		bitCount -= numBits;
	}

	void decodeNeedBytes(){
		if (!decodeBufEOF){
			decodeNeedBytesFunc(decodeBufNext - decodeBuf, decodePrivateData, decodeBuf, decodeBufSize, decodeBufEOF);
			decodeBufEnd = decodeBuf + decodeBufSize;
			decodeBufNext = decodeBuf;
		}
	}
}