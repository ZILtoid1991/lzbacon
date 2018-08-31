module lzbacon.tar;

import std.file;
import std.datetime;

/**
 * GNU sparse implementation
 */
struct GNUTarSparse{
	char[12]	offset;
	char[12]	numbytes;
}
/**
 * Unix standard tar header extensions.
 */
struct USTarExtension{
	char[6]		magic;///Header extension identification
	char[2]		version;///"00" by default
	char[32]	uname;///Stores user names
	char[32]	gname;///Stores group names
	char[8]		devmajor;
	char[8]		devminor;
	char[155]	prefix;///Extends the filename by storing path here
	char[12]	pad;///Unused by default
}
/**
 * GNU tar header extensions.
 */
struct GNUTarExtension{
	char[6]		magic;///Header extension identification
	char[2]		version;///"00" by default
	char[32]	uname;///Stores user names
	char[32]	gname;///Stores group names
	char[8]		devmajor;
	char[8]		devminor;
	char[12]	atime;///Last access time
	char[12]	ctime;///Creation time
	char[12]	offset;
	char[4]		longnames;
	char[1]		unused;///Unused by default
	GNUTarSparse[4] sparse;///Stores sparse data
	char[1]		isextended;
	char[12]	realsize;
	char[17]	pad;///Unused by default
}
/**
 * Stores the supported values of typeflag.
 */
enum Typeflag : char{
	regular			=	'0',
	hardLink		=	'1',
	symbolicLink	=	'2',
	charDevNode		=	'3',
	blockDevNode	=	'4',
	directory		=	'5',
	fifonode		=	'6',
	reserved		=	'7',
	directory		=	'D',
	longLinkname	=	'K',
	longPathname	=	'L',
	lastFile		=	'M',
	sparse			=	'S',
}
/**
 * Identifies the extensions.
 */
enum IDMagic : string{
	ustar			=	"ustar\x00",
	gnutar			=	"gnutar"
}
/**
 * Pre-POSIX tar header with extensions available in the padding.
 */
public struct TarHeader {
	public char[100]	name;///Name of file, including path, except for ustar. ASCII characters only by default.
	public char[8]		mode;///File mode, stored as an octal number.
	public char[8]		uid;///User ID.
	public char[8]		gid;///Group ID.
	public char[12]		size;///Size of file in octal.
	public char[12]		mtime;///Last modification time in octal, Unix time format.
	public char[8]		checksum;///Checksum stored as an octal number.
	public char[1]		typeflag;///Originally linkflag, this later became the typeflag.
	public char[100]	linkname;///Holds the name of the previous file having the same data as this.
	union{
		public char[255]		pad;///Holds no information by default, holds 
		public USTarExtension	ustarext;///Accesses the ustar extension fields
		public GNUTarExtension	gnutarext;///Accesses the GNU extension fields
	}
	/**
	 * Returns the filename as a proper D string.
	 * in case of ustar, it also includes the prefix extension.
	 */
	public string getFileNameAsString(){
		string result;
		if(ustarext.magic = IDMagic.ustar){//include path if ustar extensions have it
			for(int i ; i < ustarext.prefix.length ; i++){
				if(ustarext.prefix[i]=='\x00'){
					break;
				}else{
					result ~= ustarext.prefix[i];
				}
			}
		}
		for(int i ; i < name.length ; i++){
			if(name[i]=='\x00'){
				break;
			}else{
				result ~= name[i];
			}
		}
		return result;
	}
	/**
	 * Sets the filename from a string.
	 * Returns 0 if everything went right, minus values if the name is too long to fit into.
	 * Technically it can store UTF8 filenames, but it's not standard and might cause compatibility issues.
	 */
	public int setFileName(string filename){
		if(ustarext.magic = IDMagic.ustar){//include path if ustar extensions have it
			string directory = dirName(filename);
			filename = baseName(filename);
			int i;
			for(; i < directory.length && i < ustarext.prefix.length ; i++){
				//force windows style dir separators to common ones
				if(directory[i] == '\\')
					ustarext.prefix[i] = '/';
				else
					ustarext.prefix[i] = directory[i];
			}
			//return with a negative value if name is too long
			if (i < directory.length)
				return i - directory.length;
			//set remaining positions to null
			for(; i < i < ustarext.prefix.length ; i++){
				ustarext.prefix[i] = '\x00';
			}
		}
		int i;
		for(; i < filename.length && i < name.length ; i++){
			//force windows style dir separators to common ones
			if(filename[i] == '\\')
				name[i] = '/';
			else
				name[i] = directory[i];
		}
		//return with a negative value if name is too long
		if (i < filename.length)
			return i - filename.length;
		//set remaining positions to null
		for(; i < i < name.length ; i++){
			name[i] = '\x00';
		}
		return 0;
	}
	/**
	 * Returns mtime as DateTime.
	 * 95 bit implementations are not supported yet.
	 */
	public DateTime getMTime(){
		//DateTime result = DateTime(1970,1,1);
		//Duration dur = Duration();
		result += dur!"seconds"(parseOctal(mtime));
		return result;
	}
	/**
	 * Returns the size as an ulong.
	 * Max supported filesize is 8GB.
	 */
	public ulong getSize(){
		return parseOctal(size);
	}
	/**
	 * Sets the size from an ulong.
	 * Max supported filesize is 8GB.
	 */
	public void setSize(ulong val){
		size = toOctal(val);
	}
	/**
	 * Calculates the checksum of the header.
	 */
	public void calculateChecksum(){
		ulong chks;
		ubyte* input = cast(ubyte*)name.ptr;
		for(int i ; i < 512 ; i++){
			chks += input[i];
		}
		char[6] chksOctal0 = toOctal!6(chks);
		checksum = "      \00 ";
		for(int i ; i < chksOctal0.length ; i++){
			checksum[i]+=chksOctal0[i];
		}
	}
	/**
	 * Parses an octal string.
	 */
	static ulong parseOctal(char[] input){
		ulong output;
		for(int i ; i < input.length ; i++){
			if(input[i] != '\x00'){
				switch(input[i]){
					//case '0':
					default:
						break;
					case '1':
						output |= 1;
						break;
					case '2':
						output |= 2;
						break;
					case '3':
						output |= 3;
						break;
					case '4':
						output |= 4;
						break;
					case '5':
						output |= 5;
						break;
					case '6':
						output |= 6;
						break;
					case '7':
						output |= 7;
						break;
				}
				output<<=3;
			}
		}
		return output;
	}
	/**
	 * Converts an unsigned long value into an octal number.
	 */
	static char[I] toOctal(int I = 12)(ulong input){
		char[I] result;
		for(int n = I-2 ; n >= 0 ; n--){
			final switch(input & 0b0000_0111){
				case 0:
					result[n] = '0';
					break;
				case 1:
					result[n] = '1';
					break;
				case 2:
					result[n] = '2';
					break;
				case 3:
					result[n] = '3';
					break;
				case 4:
					result[n] = '4';
					break;
				case 5:
					result[n] = '5';
					break;
				case 6:
					result[n] = '6';
					break;
				case 7:
					result[n] = '7';
					break;
			}
		}
		return result;
	}
}
unittest{
	assert(TarHeader.toOctal(8) == "00000000010\00");
}